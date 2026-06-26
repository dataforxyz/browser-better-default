#!/usr/bin/env bash
# Unit tests for browser-picker's matches() and private_flag().
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../bin/browser-picker disable=SC1091
source "$HERE/../bin/browser-picker"   # main is guarded, so this only loads functions

fail=0

check() {  # <desc> <match|no> <pattern> <url>
  local desc="$1" want="$2" pat="$3" url="$4" got
  if matches "$pat" "$url"; then got=match; else got=no; fi
  if [ "$got" != "$want" ]; then
    printf 'FAIL: %-22s pat=%q url=%q  want=%s got=%s\n' "$desc" "$pat" "$url" "$want" "$got"
    fail=1
  fi
}

# boundary-aware plain matching
check "exact host"        match "github.com"          "https://github.com/x"
check "host child path"   match "github.com/org/repo" "https://github.com/org/repo/issues/3"
check "repo root"         match "github.com/org/repo" "https://github.com/org/repo"
check "not repo-staging"  no    "github.com/org/repo" "https://github.com/org/repo-staging"
check "left boundary"     no    "repo"                "https://github.com/myorg/test-repo"
check "repo exact seg"    match "repo"                "https://github.com/myorg/repo"
check "subdomain spoof"   no    "github.com"          "https://github.com.evil.com/"
check "prefix spoof"      no    "github.com"          "https://notgithub.com/"
check "port boundary"     match "github.com"          "https://github.com:443/x"
check "query boundary"    match "github.com/a"        "https://github.com/a?ref=1"

# glob
check "glob middle"       match "*.corp.example.com*" "https://mail.corp.example.com/x"
check "glob no match"     no    "*.corp.example.com*" "https://example.org/x"

# regex
check "regex alt"         match "regex:^https://(mail|cal)\.google\.com/" "https://cal.google.com/r/0"
check "regex no match"    no    "regex:^https://(mail|cal)\.google\.com/" "https://drive.google.com/"

# trailing-slash prefix
check "prefix slash"      match "internal/"           "https://host/internal/a/b"

# private_flag
pf() { local got; got="$(private_flag "$1")"; [ "$got" = "$2" ] || { printf 'FAIL: private_flag %q -> %s (want %s)\n' "$1" "$got" "$2"; fail=1; }; }
pf 'chromium --profile-directory="Profile 3"' '--incognito'
pf 'brave'                                     '--incognito'
pf 'firefox -P "default"'                      '--private-window'
pf 'zen-browser -P "Default (release)"'        '--private-window'

mp() { local got; got="$(menu_prompt "$1")"; [ "$got" = "$2" ] || { printf 'FAIL: menu_prompt %q -> %s (want %s)\n' "$1" "$got" "$2"; fail=1; }; }
mp 'https://example.com/path?token=secret#frag' 'Open https://example.com/path in…'
mp '' 'Open link in…'

[ "$fail" -eq 0 ] && echo "test_matching.sh: all passed"
exit "$fail"
