#!/usr/bin/env bash
# update-ssh-config.sh — run on the HOST. Writes/refreshes a `Host devbox-NAME`
# entry in ~/.ssh/config with the VM's current IP. Multipass may hand out a new
# IP after a host reboot; re-run this when `ssh devbox-NAME` stops connecting.
#
#   host/update-ssh-config.sh [NAME] [IDENTITY_FILE]
#     NAME           instance name (default: dev)
#     IDENTITY_FILE  private key   (default: ~/.ssh/devbox_ed25519)
# bash 3.2 compatible (macOS).
set -euo pipefail

NAME=${1:-dev}
IDENTITY=${2:-$HOME/.ssh/devbox_ed25519}
CONFIG=$HOME/.ssh/config
BEGIN="# >>> devbox $NAME (managed by devbox/host/update-ssh-config.sh) >>>"
END="# <<< devbox $NAME <<<"

ip=$(multipass info "$NAME" | awk '/^IPv4/ {print $2; exit}')
[ -n "$ip" ] || { echo "no IPv4 for '$NAME' — is it running? (multipass start $NAME)" >&2; exit 1; }

mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"
touch "$CONFIG"; chmod 600 "$CONFIG"

# Drop any previous managed block for this instance, then append a fresh one.
tmp=$(mktemp "${TMPDIR:-/tmp}/ssh-config.XXXXXX")
awk -v b="$BEGIN" -v e="$END" '$0 == b {skip=1} !skip {print} $0 == e {skip=0}' "$CONFIG" > "$tmp"
cat >> "$tmp" <<EOF
$BEGIN
Host devbox-$NAME
    HostName $ip
    User ubuntu
    IdentityFile $IDENTITY
    IdentitiesOnly yes
    # Local VM on the host-only network, recreated with fresh host keys (often
    # on a reused IP): pinning keys would only produce "host key changed" errors.
    StrictHostKeyChecking no
    UserKnownHostsFile /dev/null
    LogLevel ERROR
$END
EOF
cat "$tmp" > "$CONFIG"; rm -f "$tmp"

echo "ssh config: devbox-$NAME -> $ip"
