const assert = require("node:assert/strict");
const manifest = require("../extension/manifest.json");

let navigate;
let source;
let target;
let reply;
let sent;
let removed;
global.chrome = {
  webNavigation: { onCreatedNavigationTarget: { addListener: (listener) => { navigate = listener; } } },
  tabs: {
    get: async (id) => ({ windowId: id }),
    remove: async (id) => { removed = id; },
  },
  windows: {
    get: async (id) => {
      const type = id === 1 ? source : target;
      if (!type) throw new Error("Window closed");
      return { type };
    },
  },
  runtime: {
    sendNativeMessage: async (host, message) => {
      sent = { host, message };
      if (reply instanceof Error) throw reply;
      return reply;
    },
  },
};
require("../extension/background.js");

async function test() {
  assert.deepEqual(manifest.permissions, ["webNavigation", "nativeMessaging"]);
  assert.equal(manifest.host_permissions, undefined);

  const url = "https://example.test/path";
  target = "normal";
  reply = { ok: true };
  for (source of ["app", "popup"]) {
    sent = removed = undefined;
    await navigate({ sourceTabId: 1, tabId: 2, url });
    assert.deepEqual(sent, { host: "com.dataforxyz.browser_picker", message: { url } });
    assert.equal(removed, 2);
  }

  const skipped = [
    ["normal", "normal", url],
    ["app", "popup", url],
    ["app", undefined, url],
    ["app", "normal", "https://sub.accounts.google.com./login"],
    ["app", "normal", "mailto:user@example.test"],
  ];
  for (const [from, to, link] of skipped) {
    [source, target] = [from, to];
    sent = removed = undefined;
    await navigate({ sourceTabId: 1, tabId: 2, url: link });
    assert.equal(sent, undefined, link);
    assert.equal(removed, undefined, link);
  }

  [source, target] = ["app", "normal"];
  for (reply of [{ ok: false }, undefined, new Error("Host missing")]) {
    sent = removed = undefined;
    await navigate({ sourceTabId: 1, tabId: 2, url });
    assert.ok(sent);
    assert.equal(removed, undefined);
  }
}

test().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
