#!/usr/bin/env bash
# chrony-setup.sh — make the VM clock recover within minutes after the host
# sleeps (docs/provisioning.md#clock). Run as root; idempotent.
#
# Why chrony.conf is edited instead of using a conf.d drop-in: Ubuntu includes
# /etc/chrony/conf.d near the TOP of chrony.conf, the stock `makestep 1 3` comes
# later, and for repeated directives chrony uses the last one. A drop-in
# `makestep` is therefore silently overridden. Our line goes at the very end.
set -euo pipefail

CONF=/etc/chrony/chrony.conf
WANT='makestep 1 -1'

if (( EUID != 0 )); then
  echo "run with sudo" >&2; exit 2
fi

if ! command -v chronyd >/dev/null; then
  echo "installing chrony (replaces systemd-timesyncd)"
  DEBIAN_FRONTEND=noninteractive apt-get install -y -q chrony
fi

# Effective = the last makestep in chrony.conf, provided no confdir/include
# after it could override it. Mirrored by devbox-doctor.
effective_ok() {
  awk -v want="$WANT" '
    /^[ \t]*makestep[ \t]/ { m = $1 " " $2 " " $3; after = 0 }
    /^[ \t]*(confdir|include)[ \t]/ { after = 1 }
    END { exit !(m == want && !after) }' "$CONF"
}

if effective_ok; then
  echo "chrony: '$WANT' already effective"
else
  cp -p "$CONF" "$CONF.devbox-backup"
  sed -i -E 's/^([ \t]*makestep[ \t].*)$/# devbox: overridden at the end of this file: \1/' "$CONF"
  cat >> "$CONF" <<EOF

# devbox: step the clock whenever it is off by >1s, not only at startup. After a
# host sleep the guest clock is behind by the nap, and slewing never catches up.
# Must stay the last makestep in this file (see https://github.com/loxy/devbox).
$WANT
EOF
  effective_ok || { echo "failed to make '$WANT' effective in $CONF" >&2; exit 1; }
  echo "chrony: '$WANT' written to the end of $CONF (backup: $CONF.devbox-backup)"
fi

# Ineffective drop-in from earlier devbox versions / guides.
rm -f /etc/chrony/conf.d/99-makestep.conf

systemctl enable -q chrony
systemctl restart chrony
chronyc waitsync 6 >/dev/null 2>&1 || echo "warning: chrony not synchronized yet (outbound UDP/123 blocked?)"
chronyc makestep >/dev/null
echo "chrony: $(chronyc tracking | sed -n 's/^System time *: //p')"
