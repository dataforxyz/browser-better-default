// Browser Picker bridge — service worker.
//
// Chromium "--app=" web-app windows handle link clicks internally: a target=_blank or
// cross-site link opens in a new Chromium window, never touching the system link handler
// — so browser-picker is bypassed. This catches those new-target navigations when they
// originate from an app window, closes the Chromium tab Chromium just made, and hands the
// URL to browser-picker via a native-messaging host.

const HOST = "com.dataforxyz.browser_picker";

// Source-window types treated as "a web app". `--app=` windows are reported as "app" on
// some Chromium builds and "popup" on others, so we accept both; "normal"/"devtools"
// sources (ordinary browsing) are always left alone. A scripted OAuth/login popup opened
// from such a window is still protected by SKIP_NEW_TYPES below (it opens AS a popup).
const APP_WINDOW_TYPES = ["app", "popup"];

// If the NEW window Chromium spawns is one of these, it's almost certainly a scripted
// popup (OAuth / login / payment) that must return to its opener — never divert it.
const SKIP_NEW_TYPES = ["popup"];

// Belt-and-suspenders: providers whose links we never divert even from an app window.
const IGNORE_HOSTS = [
  "accounts.google.com",
  "login.microsoftonline.com",
  "login.live.com",
  "appleid.apple.com",
];

let port = null;
function host() {
  if (!port) {
    port = chrome.runtime.connectNative(HOST);
    port.onDisconnect.addListener(() => { port = null; });
  }
  return port;
}
function send(payload) {
  try {
    host().postMessage(payload);
  } catch (e) {
    port = null;
    try { host().postMessage(payload); } catch (_) { /* give up silently */ }
  }
}

function ignored(url) {
  let h;
  try { h = new URL(url).hostname; } catch (_) { return true; }
  return IGNORE_HOSTS.some((d) => h === d || h.endsWith("." + d));
}

async function windowTypeOfTab(tabId) {
  if (tabId == null || tabId < 0) return null;
  try {
    const tab = await chrome.tabs.get(tabId);
    const win = await chrome.windows.get(tab.windowId);
    return win.type;
  } catch (_) { return null; }
}
async function windowType(windowId) {
  if (windowId == null) return null;
  try { return (await chrome.windows.get(windowId)).type; } catch (_) { return null; }
}

chrome.webNavigation.onCreatedNavigationTarget.addListener(async (d) => {
  const url = d.url || "";
  if (!/^https?:\/\//i.test(url)) return;          // only http(s); mailto etc. route fine already

  const srcType = await windowTypeOfTab(d.sourceTabId);
  if (srcType == null || srcType === "normal" || srcType === "devtools") return; // ignore normal browsing

  const newType = await windowType(d.windowId);
  const act = APP_WINDOW_TYPES.includes(srcType)
           && !SKIP_NEW_TYPES.includes(newType)
           && !ignored(url);

  // Always report non-normal-source navigations so the first run reveals the real window
  // types in bridge.log; the host only launches the picker when act === true.
  send({ url, srcType, newType, act });

  if (act && d.tabId != null && d.tabId >= 0) {
    chrome.tabs.remove(d.tabId).catch(() => {}); // close the tab Chromium would have opened
  }
});
