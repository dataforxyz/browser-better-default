# Web-app link bridge

The optional Chromium extension routes HTTP(S) links that open a new tab or window
from a Chromium web app (`chromium --app=<url>`) through Browser Picker and its rules.

## Install

```sh
./install.sh --with-bridge           # core install + bridge
extension/install-bridge.sh          # bridge only, after core install
```

`BROWSER_PICKER_INSTALL_BRIDGE=1 ./install.sh` also opts in. The installer registers the
native host in known Chromium-family config directories and discovered web-app data
directories. It adds the extension to `--load-extension` in
`~/.config/chromium-flags.conf` and other browser flags files that already use that flag.

Restart the browser and web apps. On builds and launchers that support these flags files
(such as Omarchy Chromium), the extension loads automatically. In Google Chrome or other
builds that ignore the flag, enable **Developer mode** at `chrome://extensions` and choose
**Load unpacked** with the `extension/` directory in each relevant browser profile.
Use one loading method per profile. After creating new web-app data directories, rerun
the bridge installer if the browser cannot find the host.

## Routing and permissions

The bridge checks new navigation targets with `webNavigation` and passes eligible
URLs to a local process with `nativeMessaging`. It treats source windows reported as
`app` or `popup` as web apps, accommodating Chromium builds that use either type.
Same-tab navigations, ordinary browser windows, popup destinations, and listed sign-in
hosts are left alone. A scripted flow that opens an ordinary tab from an app window can
still be routed.

The bridge closes the destination tab after the host confirms it started the picker.
If the window lookup or handoff fails, Chromium can continue loading the link.
The host sends errors to Chromium without logging URLs. Older installations may still
have a `~/.cache/browser-picker/bridge.log` file containing URLs.

The public key in the extension manifest pins the extension ID used by the native host.
The bridge supports Chromium-family browsers.

## Uninstall

1. Remove the extension path from `--load-extension=` in the flags files the installer
   edited, or remove the extension in `chrome://extensions` if you loaded it manually.
2. Delete `NativeMessagingHosts/com.dataforxyz.browser_picker.json` from the browser
   config and web-app data directories where the installer wrote it.
3. Remove `~/.local/bin/browser-picker-host` and restart the browser and web apps.
