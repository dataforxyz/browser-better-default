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

installed=0
for dir in \
  "$HOME/.config/chromium" \
  "$HOME/.config/google-chrome" \
  "$HOME/.config/BraveSoftware/Brave-Browser" \
  "$HOME/.config/microsoft-edge" \
  "$HOME/.config/vivaldi" \
  "$HOME/.config/opera"; do
  [ -d "$dir" ] || continue
  mkdir -p "$dir/NativeMessagingHosts"
  printf '%s\n' "$MANIFEST" > "$dir/NativeMessagingHosts/$HOST_NAME.json"
  echo "  installed host manifest -> $dir/NativeMessagingHosts/$HOST_NAME.json"
  installed=$((installed + 1))
done
[ "$installed" -gt 0 ] || echo "  (no Chromium-family config dirs found yet — run a browser once, then re-run)"

cat <<EOF

Native host installed. One manual step to load the extension:

  1. Open your web-app browser and go to:  chrome://extensions
  2. Toggle "Developer mode" (top-right) ON
  3. Click "Load unpacked" and select:
        $EXTDIR
  4. Confirm the ID shown is:  $EXT_ID

Then click a link inside a web app (e.g. WhatsApp) — browser-picker should appear.
Activity is logged to ~/.cache/browser-picker/bridge.log.
EOF
