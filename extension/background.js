// Chromium web-app windows can report either "app" or "popup".
const APP_WINDOWS = ["app", "popup"];
const IDENTITY_HOSTS = [
  "accounts.google.com",
  "login.microsoftonline.com",
  "login.live.com",
  "appleid.apple.com",
];

async function windowType(tabId) {
  const { windowId } = await chrome.tabs.get(tabId);
  return (await chrome.windows.get(windowId)).type;
}

chrome.webNavigation.onCreatedNavigationTarget.addListener(async ({ url, sourceTabId, tabId }) => {
  try {
    const { hostname, protocol } = new URL(url);
    if (protocol !== "http:" && protocol !== "https:") return;

    const host = hostname.replace(/\.$/, "");
    if (IDENTITY_HOSTS.some((domain) => host === domain || host.endsWith("." + domain))) return;
    if (!APP_WINDOWS.includes(await windowType(sourceTabId))) return;

    // Keep scripted popups with their opener.
    const target = await windowType(tabId);
    if (!target || target === "popup") return;

    const reply = await chrome.runtime.sendNativeMessage("com.dataforxyz.browser_picker", { url });
    if (reply?.ok === true) await chrome.tabs.remove(tabId);
  } catch {
    // The tab may already be gone, or Chromium can continue loading it on handoff failure.
  }
});
