# Configuration

browser-picker reads two plain-text files on **every** link click (no daemon, no restart):

| File | Purpose |
|------|---------|
| `~/.config/browser-picker/browsers.conf` | the browser + profile entries offered in the menu |
| `~/.config/browser-picker/rules.conf`    | smart-default rules that open matching links directly |

Both ignore blank lines and lines starting with `#`. Fields are separated by `|||`.
You normally manage these through the **Browser Picker Rules** app (`browser-picker-rules`),
but they're easy to edit by hand.

## browsers.conf

```
Label|||command
```

- **Label** — what shows in the menu and what rules refer to, e.g. `Chromium — Work`.
- **command** — how to launch that profile; may contain quotes. The opened URL(s) are
  appended automatically. This is a local shell command snippet, so only use entries you
  trust (do not paste someone else's config blindly).

Examples:

```
Chromium — Work|||chromium --profile-directory=Default
Chromium — Personal|||chromium --profile-directory="Profile 3"
Firefox — default-release|||firefox -P "default-release"
Zen — Default (release)|||zen-browser -P "Default (release)"
Brave|||brave
```

Instead of writing these by hand, let the picker auto-add new profiles when it opens, or open
the editor and click **⟳ Rescan profiles**. Profile detection scans installed browsers and
their profiles:

- **Chromium family** (Chromium, Brave, Chrome, Edge): from each browser's
  `Local State` → `profile.info_cache`.
- **Firefox family** (Firefox, Zen): from `profiles.ini` (`[Profile*] Name=`).

Auto-rescan / Rescan only **adds** newly found profiles; it never deletes entries you've
added or kept by hand (so a bare `Brave` entry survives). Set
`BROWSER_PICKER_AUTO_RESCAN=0` to disable automatic updates and keep `browsers.conf` fully
manual.

## rules.conf

```
enabled|||pattern|||label[|||private]
```

- **enabled** — `1` (on) or `0` (off).
- **pattern** — matched against the full URL (see below).
- **label** — must exactly match a Label in `browsers.conf`. If it doesn't, the editor shows
  a ⚠ and preserves the rule (it won't silently rewrite it to another profile); the picker
  skips the broken rule and falls back to the menu.
- **private** — optional `1` opens matching links in a private/incognito window.

The **first enabled rule that matches wins**, top to bottom. Use the ▲▼ buttons in the
editor (or reorder lines) to set priority — put specific rules above broad ones.

### Pattern syntax

| Form | Matches | Example |
|------|---------|---------|
| plain text | boundary-aware substring: the text bordered by start/`/`/`:` on the left and end/`/`/`?`/`#`/`:` on the right | `github.com/acme/web` matches that repo and `…/web/issues`, **not** `…/web-staging` or `notgithub.com` |
| `*` / `?` glob | glob over the whole URL | `*://*.corp.example.com/*` |
| `regex:RE` | bash regular expression over the whole URL | `regex:^https://(mail|cal)\.google\.com/` |
| `*` (alone) | everything — a **catch-all default** for unmatched links; keep it last | `1|||*|||Chromium — Work` |

Plain text is the everyday case and the safe default: `github.com/acme/web` covers the repo
and all its child pages without matching unrelated repos or look-alike domains.

### The "Unmatched links →" default

In the editor, the **Unmatched links →** dropdown sets what happens to links no rule matched:

- **Always ask (show the menu)** — the default behaviour.
- a profile — opens unmatched links there directly. This is stored as a trailing catch-all
  `1|||*|||<label>` rule, so it has the lowest priority.

### Example rules.conf

```
1|||github.com/acme|||Chromium — Work
1|||regex:^https://(mail|cal)\.google\.com/|||Chromium — Personal
0|||figma.com|||Chromium — Personal
1|||*|||Chromium — Personal
```

## Menu command

On omarchy, browser-picker uses `omarchy-launch-walker` when available. Otherwise it uses
`walker --dmenu`. If you prefer another dmenu-style launcher, set `BROWSER_PICKER_MENU` to a
shell command that reads options on stdin and prints the chosen line on stdout. The prompt is
available as `$BROWSER_PICKER_PROMPT`:

```sh
export BROWSER_PICKER_MENU='wofi --dmenu --prompt "$BROWSER_PICKER_PROMPT"'
# or, for another Wayland launcher:
export BROWSER_PICKER_MENU='fuzzel --dmenu --prompt "$BROWSER_PICKER_PROMPT> "'
```

For links launched from `.desktop` files, put the variable somewhere inherited by your user
session (for example your compositor/session environment), not only in an interactive shell.

## Local recommender settings

The recommender is local/offline and stores recent picks in
`~/.config/browser-picker/history.json`. It starts suggesting a default on the first repeat
by default. Tune that with `~/.config/browser-picker/settings.conf`:

```ini
threshold=3
```

`BROWSER_PICKER_SUGGEST_THRESHOLD=3` also works for environments that pass it to the picker.
The minimum effective threshold is `2`.

## Default link handler

`install.sh` registers browser-picker for `http`, `https`, and `mailto` via `xdg-settings`
and `xdg-mime`. To check or change manually:

```sh
xdg-settings get default-web-browser
xdg-mime query default x-scheme-handler/https
# revert to a single browser:
xdg-settings set default-web-browser chromium.desktop
xdg-mime default chromium.desktop x-scheme-handler/http x-scheme-handler/https
```

## Uninstall / revert

There is no system-wide install. To remove browser-picker:

```sh
# choose your real browser .desktop file first
xdg-settings set default-web-browser chromium.desktop
xdg-mime default chromium.desktop x-scheme-handler/http x-scheme-handler/https
xdg-mime default org.gnome.Evolution.desktop x-scheme-handler/mailto  # optional mailto example

rm -f ~/.local/bin/browser-picker \
      ~/.local/bin/browser-picker-rules \
      ~/.local/bin/browser-picker-recommend \
      ~/.local/bin/browser-picker-profiles \
      ~/.local/bin/browser-picker-host \
      ~/.local/share/applications/browser-picker.desktop \
      ~/.local/share/applications/browser-picker-rules.desktop

# optional: remove your rules/history too
rm -rf ~/.config/browser-picker ~/.cache/browser-picker
```

If you installed the optional bridge, also remove the extension path from any
`~/.config/*-flags.conf` `--load-extension=` entries and delete
`NativeMessagingHosts/com.dataforxyz.browser_picker.json` from Chromium-family config dirs
where the bridge installer wrote it.

## Troubleshooting

- **Nothing happens on click** — install [walker](https://github.com/abenz1267/walker) or
  set `BROWSER_PICKER_MENU` to another dmenu-style command. The picker also notifies via
  `notify-send` if it can't find a menu.
- **A rule never fires** — a broader rule above it is winning. Reorder with ▲▼. Remember the
  catch-all `*` must stay last.
- **Firefox/Zen opens the wrong profile** — those browsers serve one profile at a time; if a
  different profile is already running, the link goes to it. Chromium-family handle concurrent
  profiles fine.
