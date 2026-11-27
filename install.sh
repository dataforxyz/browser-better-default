#!/usr/bin/env bash
# Install browser-picker: symlink the executables, register the .desktop files,
# seed config from the examples, and set the picker as the default link handler.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$HOME/.local/bin"
APPS="$HOME/.local/share/applications"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}/browser-picker"
INSTALL_BRIDGE="${BROWSER_PICKER_INSTALL_BRIDGE:-0}"
SET_DEFAULT=1

usage() {
  cat <<'EOF'
Usage: ./install.sh [--with-bridge|--no-bridge] [--refresh]

Installs the core browser-picker link handler by default.

Options:
  --with-bridge   Also install the Chromium/omarchy web-app bridge.
                  This edits user-level Chromium flags files and installs a
                  native-messaging host; see docs/BRIDGE.md.
  --no-bridge     Core install only (default).
  --refresh       Refresh the launchers and symlinks without changing link defaults.
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
    --refresh)
      SET_DEFAULT=0 ;;
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

first_install=0
if [ ! -e "$CFG/browsers.conf" ] && [ ! -e "$CFG/rules.conf" ]; then
  first_install=1
fi
mkdir -p "$BIN" "$APPS" "$CFG"

# Executables: symlinked so edits in the repo go live immediately.
ln -sf "$REPO/bin/browser-picker"             "$BIN/browser-picker"
ln -sf "$REPO/bin/browser-picker-apps"        "$BIN/browser-picker-apps"
ln -sf "$REPO/bin/browser-picker-rules"    "$BIN/browser-picker-rules"
ln -sf "$REPO/bin/browser-picker-recommend"   "$BIN/browser-picker-recommend"
ln -sf "$REPO/bin/browser-picker-profiles"    "$BIN/browser-picker-profiles"
ln -sf "$REPO/bin/browser-picker-menu-select" "$BIN/browser-picker-menu-select"

# Desktop entries: expand @BINDIR@ to the absolute bin path (xdg needs an abs Exec).
for d in browser-picker browser-picker-rules; do
  sed "s|@BINDIR@|$BIN|g" "$REPO/applications/$d.desktop" > "$APPS/$d.desktop"
done
update-desktop-database "$APPS" 2>/dev/null || true

# Seed config from examples without clobbering an existing setup.
[ -f "$CFG/browsers.conf" ] || cp "$REPO/config/browsers.conf.example" "$CFG/browsers.conf"
[ -f "$CFG/rules.conf" ]    || cp "$REPO/config/rules.conf.example"    "$CFG/rules.conf"
[ -f "$CFG/apps.conf" ]     || cp "$REPO/config/apps.conf.example"     "$CFG/apps.conf"

# Make the picker the default for links on request.
if [ "$SET_DEFAULT" = "1" ]; then
  if command -v xdg-settings >/dev/null 2>&1; then
    xdg-settings set default-web-browser browser-picker.desktop 2>/dev/null || true
  fi
  link_types=(x-scheme-handler/http x-scheme-handler/https x-scheme-handler/mailto)
  xdg-mime default browser-picker.desktop "${link_types[@]}"
  for link_type in "${link_types[@]}"; do
    if [ "$(xdg-mime query default "$link_type")" != browser-picker.desktop ]; then
      echo "Could not set Browser Picker as the default for $link_type." >&2
      exit 1
    fi
  done
fi

cat <<EOF
Installed browser-picker.
  • Manage rules:   browser-picker-rules   (or "Browser Better Default" in your launcher)
  • Detect profiles: open the rules editor and rescan profiles
  • Config lives in: $CFG
Click any link to see the picker. Omarchy uses its native menu.

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

if [ "$first_install" = "1" ] && [ "$SET_DEFAULT" = "1" ] && [ -t 1 ] &&
    [ -n "${WAYLAND_DISPLAY:-}" ] && command -v omarchy-shell >/dev/null 2>&1; then
  omarchy-shell shell summon browser-better-default '{"setup":true}' >/dev/null 2>&1 || true
fi
