#!/usr/bin/env bash
# create-vm.sh — run on the HOST (macOS or Linux) to create a devbox VM.
# Compatible with macOS's bash 3.2: no associative arrays, no mapfile, no sed -i.
#
#   host/create-vm.sh [options]
#     --name NAME        instance name                 (default: dev)
#     --cpus N           vCPUs                         (default: 8)
#     --memory SIZE      RAM                           (default: 32G)
#     --disk SIZE        disk; can grow later, never shrink (default: 60G)
#     --image IMAGE      Ubuntu image, stick to LTS    (default: 24.04)
#     --ssh-key FILE     public key allowed to SSH in  (default: ~/.ssh/devbox_ed25519.pub, created if missing)
#     --repo URL         devbox repo to clone in the VM (default: https://github.com/loxy/devbox.git)
#     --ref REF          branch/tag to clone           (default: main)
#     --print            only print the rendered cloud-init, launch nothing
set -euo pipefail

NAME=dev CPUS=8 MEMORY=32G DISK=60G IMAGE=24.04
SSH_KEY=$HOME/.ssh/devbox_ed25519.pub
REPO=https://github.com/loxy/devbox.git REF=main PRINT=0

while [ $# -gt 0 ]; do
  case "$1" in
    --name) NAME=$2; shift 2 ;;
    --cpus) CPUS=$2; shift 2 ;;
    --memory) MEMORY=$2; shift 2 ;;
    --disk) DISK=$2; shift 2 ;;
    --image) IMAGE=$2; shift 2 ;;
    --ssh-key) SSH_KEY=$2; shift 2 ;;
    --repo) REPO=$2; shift 2 ;;
    --ref) REF=$2; shift 2 ;;
    --print) PRINT=1; shift ;;
    -h|--help) sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

HERE=$(cd "$(dirname "$0")" && pwd)
TEMPLATE=$HERE/../cloud-init.yaml

# Dedicated host->VM key: independently revocable, used by ssh and JetBrains Gateway.
if [ ! -f "$SSH_KEY" ]; then
  if [ "$SSH_KEY" = "$HOME/.ssh/devbox_ed25519.pub" ]; then
    echo "Creating SSH key ${SSH_KEY%.pub}"
    ssh-keygen -q -t ed25519 -N '' -C "host->devbox" -f "${SSH_KEY%.pub}"
  else
    echo "SSH key not found: $SSH_KEY" >&2; exit 1
  fi
fi

# Render the template. Values are safe for sed's `|` delimiter: URLs, refs and
# ssh public keys never contain `|`.
rendered=$(mktemp "${TMPDIR:-/tmp}/devbox-cloud-init.XXXXXX")
trap 'rm -f "$rendered"' EXIT
key_line="  - \"$(tr -d '\n' < "$SSH_KEY")\""
sed -e "s|^__SSH_AUTHORIZED_KEYS__\$|$key_line|" \
    -e "s|__DEVBOX_REPO__|$REPO|g" \
    -e "s|__DEVBOX_REF__|$REF|g" \
    "$TEMPLATE" > "$rendered"

if grep -q '__[A-Z_]*__' "$rendered"; then
  echo "unrendered placeholders left in cloud-init:" >&2
  grep -n '__[A-Z_]*__' "$rendered" >&2; exit 1
fi

if [ "$PRINT" = 1 ]; then cat "$rendered"; exit 0; fi

command -v multipass >/dev/null || { echo "multipass not installed: https://multipass.run" >&2; exit 1; }
if multipass info "$NAME" >/dev/null 2>&1; then
  echo "instance '$NAME' already exists; pick another --name or 'multipass delete --purge $NAME'" >&2
  exit 1
fi

echo "Launching '$NAME' ($IMAGE, ${CPUS} CPU, $MEMORY RAM, $DISK disk). First boot installs"
echo "packages, Docker and the toolchains — expect 5–15 minutes."
# The timeout covers cloud-init too; multipass waits for it to finish.
multipass launch "$IMAGE" --name "$NAME" --cpus "$CPUS" --memory "$MEMORY" --disk "$DISK" \
  --cloud-init "$rendered" --timeout 1800

status=$(multipass exec "$NAME" -- cloud-init status --wait 2>&1 || true)
case "$status" in
  *done*) echo "cloud-init: done" ;;
  *) echo "cloud-init did not finish cleanly:" >&2; echo "$status" >&2
     echo "inspect: multipass exec $NAME -- sudo tail -50 /var/log/cloud-init-output.log" >&2
     exit 1 ;;
esac

"$HERE/update-ssh-config.sh" "$NAME" "${SSH_KEY%.pub}"

cat <<EOF

Done. Next:
  ssh devbox-$NAME            (or: multipass shell $NAME)
  devbox-doctor               lists the remaining manual steps (GitHub key, logins, secrets)
EOF
