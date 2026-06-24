#!/usr/bin/env bash
# Install the Browser Picker bridge: the native-messaging host + its manifest, so links
# opened from Chromium web-app (--app=) windows route through browser-picker.
#
# Loading the extension itself is a one-time manual step (Chromium has no supported way to
# install an unpacked extension non-interactively) — this script prints how at the end.
set -euo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXTDIR="$REPO/extension"
BIN="$HOME/.local/bin"
HOST_NAME="com.dataforxyz.browser_picker"

mkdir -p "$BIN"
ln -sf "$REPO/bin/browser-picker-host" "$BIN/browser-picker-host"

# Derive the extension ID from the public key pinned in manifest.json, so allowed_origins
# matches the ID Chromium will assign — same algorithm Chromium uses (sha256 -> a..p).
EXT_ID="$(python3 - "$EXTDIR/manifest.json" <<'PY'
import base64, hashlib, json, sys
key = json.load(open(sys.argv[1]))["key"]
der = base64.b64decode(key)
h = hashlib.sha256(der).hexdigest()[:32]
print("".join(chr(ord("a") + int(c, 16)) for c in h))
PY
)"
echo "Extension ID: $EXT_ID"

# Write the host manifest into every Chromium-family profile dir that exists.
read -r -d '' MANIFEST <<JSON || true
{
  "name": "$HOST_NAME",
  "description": "Browser Picker bridge native host",
  "path": "$BIN/browser-picker-host",
  "type": "stdio",
  "allowed_origins": ["chrome-extension://$EXT_ID/"]
}
JSON

install_manifest() {  # <config-dir>
  mkdir -p "$1/NativeMessagingHosts"
  printf '%s\n' "$MANIFEST" > "$1/NativeMessagingHosts/$HOST_NAME.json"
  echo "  installed host manifest -> $1/NativeMessagingHosts/$HOST_NAME.json"
}

installed=0
# Standard Chromium-family config dirs — only if the browser is actually present.
for dir in \
  "$HOME/.config/chromium" \
  "$HOME/.config/google-chrome" \
  "$HOME/.config/BraveSoftware/Brave-Browser" \
  "$HOME/.config/microsoft-edge" \
  "$HOME/.config/vivaldi" \
  "$HOME/.config/opera"; do
  [ -d "$dir" ] || continue
  install_manifest "$dir"
  installed=$((installed + 1))
done

# Custom data dirs that web-app launchers pin with --user-data-dir (omarchy web apps can
# run in their own dir, e.g. ~/.config/chromium-webapps). Chromium's native-host search is
# per data dir, so the manifest must live in each of these too. These are intentional, so
# create them even if a dir hasn't been launched yet.
while IFS= read -r dir; do
  [ -n "$dir" ] || continue
  install_manifest "$dir"
  installed=$((installed + 1))
done < <(grep -hoE -- '--user-data-dir=[^ ]+' "$HOME/.local/share/applications/"*.desktop 2>/dev/null \
         | sed 's/--user-data-dir=//' | sort -u)

[ "$installed" -gt 0 ] || echo "  (no Chromium-family config dirs found yet — run a browser once, then re-run)"

cat <<EOF

Native host installed. Now load the extension — once per data dir that runs web apps
(Chromium can't install an unpacked extension non-interactively). For each web-app browser
window / data dir:

  1. Go to:  chrome://extensions
  2. Toggle "Developer mode" (top-right) ON
  3. Click "Load unpacked" and select:
        $EXTDIR
  4. Confirm the ID shown is:  $EXT_ID

Default-profile apps share one load; apps launched with their own --user-data-dir
(e.g. ~/.config/chromium-webapps) need the extension loaded from a window of that dir too.
Then click a link inside a web app (e.g. WhatsApp) — browser-picker should appear.
Activity is logged to ~/.cache/browser-picker/bridge.log.
EOF
