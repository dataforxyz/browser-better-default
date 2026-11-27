#!/usr/bin/env bash
# End-to-end integration tests for browser-picker with local desktop apps & web apps.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

export XDG_CONFIG_HOME="$TMP/config"
export XDG_DATA_HOME="$TMP/share"
export XDG_DATA_DIRS="$TMP/sys_share"
export BROWSER_PICKER_AUTO_RESCAN=0
export PATH="$ROOT/bin:$TMP/mockbin:$PATH"

mkdir -p "$XDG_CONFIG_HOME/browser-picker" "$XDG_DATA_HOME/applications" "$XDG_DATA_DIRS/applications" "$TMP/mockbin"

LOG="$TMP/launches.log"
MENU_SEEN="$TMP/menu_seen.txt"

cat > "$TMP/mockbin/notify-send" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TMP/mockbin/notify-send"

cat > "$TMP/mockbin/mock-browser" <<EOF
#!/usr/bin/env bash
printf 'BROWSER:%s\n' "\$*" >> "$LOG"
EOF
chmod +x "$TMP/mockbin/mock-browser"

cat > "$TMP/mockbin/mock-t3" <<EOF
#!/usr/bin/env bash
printf 'T3:%s\n' "\$*" >> "$LOG"
EOF
chmod +x "$TMP/mockbin/mock-t3"

cat > "$TMP/mockbin/omarchy-launch-webapp" <<EOF
#!/usr/bin/env bash
printf 'WEBAPP:%s\n' "\$*" >> "$LOG"
EOF
chmod +x "$TMP/mockbin/omarchy-launch-webapp"

cat > "$XDG_DATA_HOME/applications/com.t3tools.T3Code.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=T3 Code (Nightly)
Exec=$TMP/mockbin/mock-t3 %U
NoDisplay=true
MimeType=x-scheme-handler/t3code;
EOF

cat > "$XDG_DATA_HOME/applications/Figma.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Figma
Exec=omarchy-launch-webapp https://figma.com/ --profile-directory="Profile 3"
EOF

cat > "$XDG_CONFIG_HOME/browser-picker/browsers.conf" <<'EOF'
Firefox — default|||mock-browser -P "default"
Chromium — Work|||mock-browser --profile-directory="Default"
EOF

cat > "$XDG_CONFIG_HOME/browser-picker/rules.conf" <<'EOF'
# rules
EOF

# Seed heavy unrelated history for Firefox so we prove T3 Code still ranks #1 on app.t3.codes.
for i in 1 2 3 4 5; do
  "$ROOT/bin/browser-picker-recommend" record --url "https://news.example.com/a/$i" --label "Firefox — default"
done

wait_for_log() {
  local want="$1" tries=30
  while (( tries-- > 0 )); do
    if [ -f "$LOG" ] && grep -Fq -- "$want" "$LOG"; then
      return 0
    fi
    sleep 0.05
  done
  echo "FAIL: expected log line containing: $want" >&2
  [ -f "$LOG" ] && cat "$LOG" >&2
  exit 1
}

# 1) First T3 thread link: T3 Code should be #1 in the menu, with no Private twin for T3 Code.
export BROWSER_PICKER_MENU="tee '$MENU_SEEN' >/dev/null; printf 'T3 Code\n'"
"$ROOT/bin/browser-picker" "https://app.t3.codes/threads/env-1/thread-1"
wait_for_log "T3:t3code://threads/env-1/thread-1"

first_item="$(head -n 1 "$MENU_SEEN")"
[ "$first_item" = "T3 Code" ] || { echo "FAIL: expected first menu item 'T3 Code', got '$first_item'" >&2; cat "$MENU_SEEN" >&2; exit 1; }
if grep -Fq "T3 Code  🕶 Private" "$MENU_SEEN"; then
  echo "FAIL: local app should not get a Private twin" >&2
  cat "$MENU_SEEN" >&2
  exit 1
fi
grep -Fq "Firefox — default  🕶 Private" "$MENU_SEEN" || { echo "FAIL: browser should keep Private twin" >&2; exit 1; }

# 2) Second T3 thread link: should offer ⭐ app.t3.codes → T3 Code; picking it writes rule & launches T3.
: > "$LOG"
export BROWSER_PICKER_MENU="tee '$MENU_SEEN' >/dev/null; printf '⭐  app.t3.codes → T3 Code\n'"
"$ROOT/bin/browser-picker" "https://app.t3.codes/threads/env-1/thread-2"
wait_for_log "T3:t3code://threads/env-1/thread-2"

grep -Fq "⭐  app.t3.codes → T3 Code" "$MENU_SEEN" || { echo "FAIL: missing learned T3 suggestion" >&2; cat "$MENU_SEEN" >&2; exit 1; }
grep -Fq "1|||app.t3.codes|||T3 Code" "$XDG_CONFIG_HOME/browser-picker/rules.conf" || { echo "FAIL: rule not written" >&2; exit 1; }

# 3) Third T3 thread link: rule skips the menu completely and opens in T3 Code.
: > "$LOG"
: > "$MENU_SEEN"
export BROWSER_PICKER_MENU="echo SHOULD_NOT_RUN > '$MENU_SEEN'"
"$ROOT/bin/browser-picker" "https://app.t3.codes/threads/env-2/thread-3"
wait_for_log "T3:t3code://threads/env-2/thread-3"
[ ! -s "$MENU_SEEN" ] || { echo "FAIL: menu should have been skipped by T3 rule" >&2; exit 1; }

# 4) Non-deep-linkable app.t3.codes/settings falls through T3 rule to a browser rule below it.
printf '1|||app.t3.codes|||Firefox — default\n' >> "$XDG_CONFIG_HOME/browser-picker/rules.conf"
: > "$LOG"
"$ROOT/bin/browser-picker" "https://app.t3.codes/settings/general"
wait_for_log "BROWSER:-P default https://app.t3.codes/settings/general"

# 5) Unrelated URL does not show T3 Code or Figma — Web App in the menu.
export BROWSER_PICKER_MENU="tee '$MENU_SEEN' >/dev/null; printf ''\n"
"$ROOT/bin/browser-picker" "https://example.com/blog"
if grep -Eq "^(T3 Code|Figma — Web App)$" "$MENU_SEEN"; then
  echo "FAIL: unrelated URL should not show T3 Code or Figma — Web App" >&2
  cat "$MENU_SEEN" >&2
  exit 1
fi

# 6) Figma URL offers Figma — Web App (without hijacking #1 ahead of Firefox, and without Private twin).
: > "$LOG"
export BROWSER_PICKER_MENU="tee '$MENU_SEEN' >/dev/null; printf 'Figma — Web App\n'"
"$ROOT/bin/browser-picker" "https://www.figma.com/design/abc/Deck"
wait_for_log "WEBAPP:https://www.figma.com/design/abc/Deck --profile-directory=Profile 3"
first_fig="$(head -n 1 "$MENU_SEEN")"
[ "$first_fig" = "Firefox — default" ] || { echo "FAIL: web app should not outrank primary browser on first click, got '$first_fig'" >&2; cat "$MENU_SEEN" >&2; exit 1; }
if grep -Fq "Figma — Web App  🕶 Private" "$MENU_SEEN"; then
  echo "FAIL: web app should not get a Private twin" >&2
  exit 1
fi

# 7) T3 /new prompt link skips menu via existing app.t3.codes rule and opens in T3 Code.
: > "$LOG"
"$ROOT/bin/browser-picker" "https://app.t3.codes/new?prompt=Fix+the+build&repo=owner/name"
wait_for_log "T3:t3code://new?prompt=Fix+the+build&repo=owner/name"

# 8) Multi-URL (%U) call: first URL opens in T3 Code, remaining URLs are preserved (not dropped).
: > "$LOG"
export BROWSER_PICKER_MENU="printf 'Firefox — default\n'"
"$ROOT/bin/browser-picker" "https://app.t3.codes/threads/env-9/thread-9" "https://example.org/second"
wait_for_log "T3:t3code://threads/env-9/thread-9"
wait_for_log "BROWSER:-P default https://example.org/second"

# 9) Explicit private rule (4th field = 1) on a local app must NOT open a regular app session.
cat > "$XDG_CONFIG_HOME/browser-picker/rules.conf" <<'EOF'
1|||app.t3.codes|||T3 Code|||1
1|||*|||Firefox — default
EOF
: > "$LOG"
: > "$MENU_SEEN"
export BROWSER_PICKER_MENU="tee '$MENU_SEEN' >/dev/null; printf 'Firefox — default  🕶 Private\n'"
"$ROOT/bin/browser-picker" "https://app.t3.codes/threads/env-p/thread-p"
wait_for_log "BROWSER:-P default --incognito https://app.t3.codes/threads/env-p/thread-p"
if grep -Fq "T3:" "$LOG"; then
  echo "FAIL: private rule must not launch non-private local app" >&2
  cat "$LOG" >&2
  exit 1
fi

# 10) Disabled local app in apps.conf falls through saved T3 rule to browser catch-all below it.
cat > "$XDG_CONFIG_HOME/browser-picker/rules.conf" <<'EOF'
1|||app.t3.codes|||T3 Code
1|||*|||Firefox — default
EOF
printf 'T3 Code|||*|||disabled\n' > "$XDG_CONFIG_HOME/browser-picker/apps.conf"
: > "$LOG"
: > "$MENU_SEEN"
export BROWSER_PICKER_MENU="echo SHOULD_NOT_RUN > '$MENU_SEEN'"
"$ROOT/bin/browser-picker" "https://app.t3.codes/threads/env-d/thread-d"
wait_for_log "BROWSER:-P default https://app.t3.codes/threads/env-d/thread-d"
[ ! -s "$MENU_SEEN" ] || { echo "FAIL: disabled app rule should fall through to catch-all" >&2; exit 1; }

# 11) Two app rules in sequence: first returns exit 2 (no_url), second launches (verifies app_rc reset).
cat > "$TMP/mockbin/mock-custom" <<EOF
#!/usr/bin/env bash
printf 'CUSTOM:%s\n' "\$*" >> "$LOG"
EOF
chmod +x "$TMP/mockbin/mock-custom"
cat > "$XDG_CONFIG_HOME/browser-picker/apps.conf" <<EOF
My Local App|||my.local.app|||$TMP/mockbin/mock-custom --open {url}
EOF
cat > "$XDG_CONFIG_HOME/browser-picker/rules.conf" <<'EOF'
1|||my.local.app|||T3 Code
1|||my.local.app|||My Local App
1|||*|||Firefox — default
EOF
: > "$LOG"
: > "$MENU_SEEN"
export BROWSER_PICKER_MENU="echo SHOULD_NOT_RUN > '$MENU_SEEN'"
"$ROOT/bin/browser-picker" "https://my.local.app/doc/42"
wait_for_log "CUSTOM:--open https://my.local.app/doc/42"
if grep -Fq "BROWSER:" "$LOG" || [ -s "$MENU_SEEN" ]; then
  echo "FAIL: second app rule should stop rule loop cleanly" >&2
  cat "$LOG" >&2
  exit 1
fi

# 12) Stale private habit for a local app label must NOT become a non-private ⭐ app shortcut.
: > "$XDG_CONFIG_HOME/browser-picker/rules.conf"
rm -f "$XDG_CONFIG_HOME/browser-picker/history.json"
"$ROOT/bin/browser-picker-recommend" record --url "https://my.local.app/doc/1" --label "My Local App" --private 1
"$ROOT/bin/browser-picker-recommend" record --url "https://my.local.app/doc/2" --label "My Local App" --private 1
export BROWSER_PICKER_MENU="tee '$MENU_SEEN' >/dev/null; printf ''\n"
"$ROOT/bin/browser-picker" "https://my.local.app/doc/3"
if grep -Fq "⭐" "$MENU_SEEN"; then
  echo "FAIL: private habit must not become a non-private local-app ⭐ shortcut" >&2
  cat "$MENU_SEEN" >&2
  exit 1
fi

# 13) Detected Zoom offers a meeting default with no history. A saved rule
# applies across regions and leaves Zoom's ordinary pages alone.
cat > "$XDG_DATA_HOME/applications/Zoom.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Zoom
Exec=$TMP/mockbin/mock-t3 %U
MimeType=x-scheme-handler/zoommtg;
EOF
rm -f "$XDG_CONFIG_HOME/browser-picker/history.json"
export BROWSER_PICKER_MENU="tee '$MENU_SEEN' >/dev/null; printf '%s\n' '⭐  Always open Zoom meetings in Zoom'"
"$ROOT/bin/browser-picker" "https://us02web.zoom.us/j/123456789?pwd=test"
wait_for_log "T3:zoommtg://zoom.us/join?action=join&confno=123456789&pwd=test"
grep -Fq "⭐  Always open Zoom meetings in Zoom" "$MENU_SEEN"
printf '1|||*|||Firefox — default\n' >> "$XDG_CONFIG_HOME/browser-picker/rules.conf"
export BROWSER_PICKER_MENU="echo SHOULD_NOT_RUN > '$MENU_SEEN'"
: > "$MENU_SEEN"
"$ROOT/bin/browser-picker" "https://us06web.zoom.us/wc/join/987654321"
wait_for_log "T3:zoommtg://zoom.us/join?action=join&confno=987654321"
"$ROOT/bin/browser-picker" "https://zoom.us/download"
wait_for_log "BROWSER:-P default https://zoom.us/download"
"$ROOT/bin/browser-picker" "https://zoom.us.example.invalid/j/123456789"
wait_for_log "BROWSER:-P default https://zoom.us.example.invalid/j/123456789"
[ ! -s "$MENU_SEEN" ]

echo "test_picker_apps.sh: all passed"
