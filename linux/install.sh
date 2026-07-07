#!/usr/bin/env bash
#
# install.sh - install the winctl wrapper on the Linux host running Claude Code.
#
# Symlinks (or copies) winctl into a bin dir on PATH and scaffolds the config
# file. Safe to re-run. Designed to be portable: clone the repo on any Linux
# box and run this.
#
#   ./install.sh                      # symlink into ~/.local/bin
#   ./install.sh --copy               # copy instead of symlink
#   ./install.sh --bindir /usr/local/bin   # choose target dir (may need sudo)
#
set -euo pipefail

SRC_DIR="$(cd "$(dirname "$0")" && pwd)"
BINDIR="$HOME/.local/bin"
MODE="link"

while [ $# -gt 0 ]; do
  case "$1" in
    --copy)   MODE="copy"; shift ;;
    --bindir) BINDIR="$2"; shift 2 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

mkdir -p "$BINDIR"
chmod +x "$SRC_DIR/winctl"

if [ "$MODE" = "copy" ]; then
  cp "$SRC_DIR/winctl" "$BINDIR/winctl"
else
  ln -sf "$SRC_DIR/winctl" "$BINDIR/winctl"
fi
echo "Installed winctl -> $BINDIR/winctl"

case ":$PATH:" in
  *":$BINDIR:"*) ;;
  *) echo "NOTE: $BINDIR is not on PATH. Add it, e.g.:"
     echo "  echo 'export PATH=\"$BINDIR:\$PATH\"' >> ~/.bashrc" ;;
esac

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/winclaude"
CONFIG="$CONFIG_DIR/config"
if [ ! -f "$CONFIG" ]; then
  mkdir -p "$CONFIG_DIR"
  cat > "$CONFIG" <<'EOF'
# winclaude config - sourced by winctl
# Required: user@host of the Windows target
WINBOX=user@windows-host
# Install dir on the target (forward slashes)
WINCLAUDE_DIR=C:/claude-session
# Extra ssh options (optional), e.g. custom port or key:
# WINSSH_OPTS="-p 22 -i ~/.ssh/id_ed25519"
EOF
  echo "Wrote starter config: $CONFIG  (edit WINBOX to point at the Windows target)"
else
  echo "Config already exists: $CONFIG (left unchanged)"
fi
