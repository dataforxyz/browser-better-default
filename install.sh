#!/usr/bin/env bash
# Install browser-picker: symlink the executables, register the .desktop files,
# seed config from the examples, and set the picker as the default link handler.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}/browser-picker"
INSTALL_BRIDGE="${BROWSER_PICKER_INSTALL_BRIDGE:-0}"

usage() {
  cat <<'EOF'
Usage: ./install.sh [--with-bridge|--no-bridge]

Installs the core browser-picker link handler by default.

Options:
  --with-bridge   Also install the Chromium/omarchy web-app bridge.
                  This edits user-level Chromium flags files and installs a
                  native-messaging host; see docs/BRIDGE.md.
  --no-bridge     Core install only (default).
  -h, --help      Show this help.

Environment:
  BROWSER_PICKER_INSTALL_BRIDGE=1  Same as --with-bridge.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --with-bridge|--install-bridge)
      INSTALL_BRIDGE=1 ;;
    --no-bridge|--without-bridge)
      INSTALL_BRIDGE=0 ;;
    -h|--help)
      usage
      exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2 ;;
  esac
  shift
done

case "$INSTALL_BRIDGE" in
  1|true|TRUE|yes|YES|on|ON) INSTALL_BRIDGE=1 ;;
  0|false|FALSE|no|NO|off|OFF|"") INSTALL_BRIDGE=0 ;;
  *)
    echo "Invalid BROWSER_PICKER_INSTALL_BRIDGE value: $INSTALL_BRIDGE" >&2
    exit 2 ;;
esac

mkdir -p "$BIN" "$APPS" "$CFG"

# Executables: symlinked so edits in the repo go live immediately.
ln -sf "$REPO/bin/browser-picker"           "$BIN/browser-picker"
ln -sf "$REPO/bin/browser-picker-rules"     "$BIN/browser-picker-rules"
ln -sf "$REPO/bin/browser-picker-recommend" "$BIN/browser-picker-recommend"
ln -sf "$REPO/bin/browser-picker-profiles"  "$BIN/browser-picker-profiles"

# Desktop entries: expand @BINDIR@ to the absolute bin path (xdg needs an abs Exec).
for d in browser-picker browser-picker-rules; do
  sed "s|@BINDIR@|$BIN|g" "$REPO/applications/$d.desktop" > "$APPS/$d.desktop"
done
update-desktop-database "$APPS" 2>/dev/null || true

# Seed config from examples without clobbering an existing setup.
[ -f "$CFG/browsers.conf" ] || cp "$REPO/config/browsers.conf.example" "$CFG/browsers.conf"
[ -f "$CFG/rules.conf" ]    || cp "$REPO/config/rules.conf.example"    "$CFG/rules.conf"

# Make the picker the default for web links.
command -v xdg-settings >/dev/null 2>&1 && \
  xdg-settings set default-web-browser browser-picker.desktop 2>/dev/null || true
xdg-mime default browser-picker.desktop \
  x-scheme-handler/http x-scheme-handler/https x-scheme-handler/mailto 2>/dev/null || true

cat <<EOF
Installed browser-picker.
  • Manage rules:   browser-picker-rules   (or "Browser Picker Rules" in your launcher)
  • Detect profiles: open the rules app and click "⟳ Rescan profiles"
  • Config lives in: $CFG
Click any link to see the picker. Requires walker (preferred) or another menu configured
with BROWSER_PICKER_MENU.

Optional: Chromium/omarchy web-app windows bypass the normal system link handler. To route
links opened from those app windows through browser-picker too, run:
  ./install.sh --with-bridge
See docs/BRIDGE.md first; it installs a native-messaging host and edits browser flags files.
EOF

if [ "$INSTALL_BRIDGE" = "1" ]; then
  echo
  echo "Installing optional Chromium/omarchy web-app bridge (--with-bridge)..."
  "$REPO/extension/install-bridge.sh"
fi
