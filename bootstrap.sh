#!/usr/bin/env bash
# bootstrap.sh — user-level dev tooling for a devbox VM. Idempotent: safe to
# re-run any time (cloud-init runs it once on first boot).
#
# Installs: Volta + Node, mise + Go, Claude Code (native), and links bin/* into
# ~/.local/bin. Options via env or ~/.config/devbox/bootstrap.conf:
#   NODE_VERSION=lts   GO_VERSION=latest   INSTALL_CLAUDE=1
#   GIT_NAME=…  GIT_EMAIL=…   (only applied if no global git identity exists)
set -euo pipefail

DEVBOX_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
NODE_VERSION=${NODE_VERSION:-lts}
GO_VERSION=${GO_VERSION:-latest}
INSTALL_CLAUDE=${INSTALL_CLAUDE:-1}
GIT_NAME=${GIT_NAME:-}
GIT_EMAIL=${GIT_EMAIL:-}
CONFIG=${XDG_CONFIG_HOME:-$HOME/.config}/devbox/bootstrap.conf
# shellcheck source=/dev/null
[[ -f $CONFIG ]] && source "$CONFIG"

export VOLTA_HOME=$HOME/.volta
export PATH="$HOME/.local/bin:$HOME/.local/share/mise/shims:$VOLTA_HOME/bin:$PATH"

step() { printf '\n==> %s\n' "$*"; }
have() { command -v "$1" >/dev/null 2>&1; }

if (( EUID == 0 )); then
  echo "run as the dev user, not root" >&2; exit 2
fi

step "PATH in ~/.profile"
# Non-interactive login shells (IDE backends, `ssh host cmd`, agents spawning
# MCP servers) read ~/.profile but not the PATH lines installers add to
# ~/.bashrc, which returns early when not interactive. Rewritten on every run.
begin='# >>> devbox: tool paths >>>'
end='# <<< devbox: tool paths <<<'
block=$(cat <<EOF
$begin
export VOLTA_HOME="\$HOME/.volta"
export PATH="\$HOME/.local/bin:\$HOME/.local/share/mise/shims:\$VOLTA_HOME/bin:\$PATH"
$end
EOF
)
touch ~/.profile
current=$(awk -v b="$begin" -v e="$end" '$0 == b {on=1} on {print} $0 == e {on=0}' ~/.profile)
if [[ $current == "$block" ]]; then
  echo "up to date"
else
  awk -v b="$begin" -v e="$end" '$0 == b {skip=1} !skip {print} $0 == e {skip=0}' ~/.profile > ~/.profile.devbox-tmp
  printf '\n%s\n' "$block" >> ~/.profile.devbox-tmp
  mv ~/.profile.devbox-tmp ~/.profile
  echo "written"
fi

step "Volta + Node ($NODE_VERSION)"
# Node is needed even though Claude Code isn't installed via npm: MCP servers
# and tooling launched via `npx` depend on it.
[[ -x $VOLTA_HOME/bin/volta ]] || curl -fsSL https://get.volta.sh | bash
if volta list node --format plain 2>/dev/null | grep -q '(default)'; then
  echo "default node present: $(node --version)"
else
  volta install "node@$NODE_VERSION"
fi

step "mise + Go ($GO_VERSION)"
[[ -x $HOME/.local/bin/mise ]] || curl -fsSL https://mise.run | sh
if mise ls --global go 2>/dev/null | grep -q .; then
  echo "global go present: $(go version)"
else
  mise use -g "go@$GO_VERSION"
fi

if [[ $INSTALL_CLAUDE == 1 ]]; then
  step "Claude Code (native installer, auto-updates, needs no Node)"
  if have claude; then
    echo "present: $(claude --version 2>/dev/null | head -1)"
  else
    curl -fsSL https://claude.ai/install.sh | bash
  fi
fi

step "devbox commands -> ~/.local/bin"
mkdir -p ~/.local/bin
for f in "$DEVBOX_DIR"/bin/*; do
  ln -sfn "$f" ~/.local/bin/"$(basename "$f")"
  echo "  $(basename "$f")"
done

if [[ -n $GIT_NAME && -n $GIT_EMAIL ]] && ! git config --global user.name >/dev/null; then
  step "git identity"
  git config --global user.name "$GIT_NAME"
  git config --global user.email "$GIT_EMAIL"
fi

mkdir -p ~/dev
step "done — run: devbox-doctor   (log out/in once so the docker group applies)"
