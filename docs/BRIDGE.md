# Web-app link bridge

Chromium **web-app windows** (`chromium --app=<url>`, e.g. omarchy web apps) handle link
clicks *internally*: a `target=_blank` or cross-site link opens in a new Chromium window and
never calls the system link handler — so `browser-picker` is bypassed. `mailto:` and other
true external protocols still reach the picker; `http(s)` links from app windows do not.

This bridge fixes that with a small MV3 extension + a native-messaging host:

```
app-window link click
  └─▶ extension (background.js)         catches onCreatedNavigationTarget from an app window,
        │                                closes the tab Chromium was about to open
        └─▶ native host (browser-picker-host)   reads the URL off stdin
              └─▶ browser-picker <url>           your normal picker / smart-default rules
```

## Install

```sh
extension/install-bridge.sh          # installs the native host + its manifest (Chromium/Brave/…)
```

Then load the extension once, by hand (Chromium can't persistently install an unpacked
extension from the CLI):

1. `chrome://extensions` → enable **Developer mode**
2. **Load unpacked** → select the `extension/` directory
3. Confirm the ID matches the one `install-bridge.sh` printed

The extension ID is pinned by the `key` field in `manifest.json`, so the host's
`allowed_origins` always matches without copying IDs around.

## How it decides what to divert

`background.js` only acts when **all** hold:

- the link's **source window** is a web-app window (`APP_WINDOW_TYPES` — `app`/`popup`;
  ordinary `normal` browsing windows are never touched), and
- the **new** window Chromium spawned is not a `popup` (`SKIP_NEW_TYPES`) — scripted
  OAuth/login/payment popups open *as* popups and must return to their opener, so they're
  left alone, and
- the host isn't in `IGNORE_HOSTS` (extra guard for common identity providers).

Every non-`normal`-source navigation is logged to `~/.cache/browser-picker/bridge.log`
(`nav src=… new=… act=… <url>`), so first-run behaviour — including the real window types on
your Chromium build — is visible. Tune the constants at the top of `background.js` if needed.

## Limitations

- A link that navigates the **app window itself** (same tab, not a new window) is not
  intercepted — doing so would break in-app OAuth redirects. Only new-window/new-tab links
  are diverted.
- The extension load is manual and per-profile (Chromium limitation).
