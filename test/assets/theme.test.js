const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");

const root = path.resolve(__dirname, "../..");
const template = fs.readFileSync(path.join(root, "lib/residency_schedule_web/components/layouts/root.html.heex"), "utf8");
const bootstrap = [...template.matchAll(/<script>([\s\S]*?)<\/script>/g)].map(match => match[1]).join("\n");

function browser({ preference = null, dark = false, blockedStorage = false } = {}) {
  const attributes = new Map();
  const listeners = new Map();
  const mediaListeners = new Set();
  const storage = new Map(preference === null ? [] : [["phx:theme", preference]]);
  const writes = [];
  const buttons = ["system", "light", "dark"].map(theme => ({
    dataset: { phxTheme: theme },
    attributes: new Map(),
    setAttribute(key, value) { this.attributes.set(key, value); }
  }));
  const media = {
    matches: dark,
    addEventListener: (_type, listener) => mediaListeners.add(listener),
    removeEventListener: (_type, listener) => mediaListeners.delete(listener),
    addListener: listener => mediaListeners.add(listener),
    removeListener: listener => mediaListeners.delete(listener)
  };
  const localStorage = {
    getItem(key) { if (blockedStorage) throw new Error("Storage denied"); return storage.get(key) ?? null; },
    setItem(key, value) { if (blockedStorage) throw new Error("Storage denied"); writes.push([key, value]); storage.set(key, value); },
    removeItem(key) { if (blockedStorage) throw new Error("Storage denied"); writes.push([key, null]); storage.delete(key); }
  };
  const document = { querySelectorAll: () => buttons, documentElement: {
    setAttribute: (key, value) => attributes.set(key, value),
    removeAttribute: key => attributes.delete(key),
    hasAttribute: key => attributes.has(key),
    getAttribute: key => attributes.get(key) ?? null,
    dataset: {}
  }};
  const window = {
    localStorage,
    matchMedia: () => media,
    addEventListener(type, listener) {
      if (!listeners.has(type)) listeners.set(type, new Set());
      listeners.get(type).add(listener);
    },
    removeEventListener: (type, listener) => listeners.get(type)?.delete(listener)
  };
  const context = vm.createContext({ window, document, localStorage, matchMedia: window.matchMedia });
  const dispatch = (type, event) => [...(listeners.get(type) || [])].forEach(listener => listener(event));
  const run = () => vm.runInContext(bootstrap, context);
  run();
  dispatch("DOMContentLoaded", {});
  return {
    run, writes, storage, listeners, mediaListeners, buttons,
    theme: () => attributes.get("data-theme"),
    choose: theme => dispatch("phx:set-theme", { target: { dataset: { phxTheme: theme } } }),
    receive: (key, newValue) => {
      if (key === "phx:theme" || key === null) {
        if (newValue === null) storage.delete("phx:theme"); else storage.set("phx:theme", newValue);
      }
      dispatch("storage", { key, newValue, storageArea: localStorage });
    },
    navigate: () => dispatch("phx:navigate", {}),
    system: value => { media.matches = value; [...mediaListeners].forEach(listener => listener({ matches: value })); }
  };
}

test("root supplies a synchronous theme bootstrap before body paint", () => {
  assert.ok(bootstrap.trim().length > 0);
  assert.ok(template.indexOf(bootstrap) < template.indexOf("<body"));
});

for (const dark of [false, true]) {
  for (const preference of [null, "system", "invalid"]) {
    test(`system preference ${preference} resolves OS ${dark ? "dark" : "light"}`, () => {
      const page = browser({ dark, preference });
      assert.equal(page.theme(), dark ? "dark" : "light");
      page.system(!dark);
      assert.equal(page.theme(), dark ? "light" : "dark");
    });
  }
}

for (const preference of ["light", "dark"]) {
  test(`saved ${preference} overrides OS changes`, () => {
    const page = browser({ dark: preference !== "dark", preference });
    assert.equal(page.theme(), preference);
    page.system(preference === "dark");
    assert.equal(page.theme(), preference);
  });
}

test("manual preference persists and system choice resumes live OS updates", () => {
  const page = browser({ dark: true });
  page.choose("light");
  assert.equal(page.theme(), "light");
  assert.equal(page.storage.get("phx:theme"), "light");
  page.choose("dark");
  assert.equal(page.theme(), "dark");
  assert.equal(page.storage.get("phx:theme"), "dark");
  page.choose("system");
  assert.equal(page.theme(), "dark");
  assert.equal(page.storage.has("phx:theme"), false);
  page.system(false);
  assert.equal(page.theme(), "light");
});

test("theme controls expose the selected preference independently from resolved system theme", () => {
  const page = browser({ dark: true });
  const selected = () => page.buttons.filter(button => button.attributes.get("aria-pressed") === "true").map(button => button.dataset.phxTheme);
  assert.deepEqual(selected(), ["system"]);
  page.choose("light");
  assert.deepEqual(selected(), ["light"]);
  page.choose("dark");
  assert.deepEqual(selected(), ["dark"]);
  page.choose("system");
  assert.deepEqual(selected(), ["system"]);
});

test("another tab updates theme without writing the preference back", () => {
  const page = browser({ preference: "light", dark: true });
  const before = page.writes.length;
  page.receive("phx:theme", "dark");
  assert.equal(page.theme(), "dark");
  page.receive("phx:theme", null);
  assert.equal(page.theme(), "dark");
  page.system(false);
  assert.equal(page.theme(), "light");
  assert.equal(page.writes.length, before);
  page.receive("unrelated", "dark");
  assert.equal(page.theme(), "light");
});

test("storage clearing and invalid external preferences fall back to system", () => {
  const page = browser({ preference: "light", dark: true });
  page.receive(null, null);
  assert.equal(page.theme(), "dark");
  page.receive("phx:theme", "garbage");
  assert.equal(page.theme(), "dark");
  page.system(false);
  assert.equal(page.theme(), "light");
});

test("blocked storage still allows startup, manual changes, and system changes", () => {
  const page = browser({ dark: true, blockedStorage: true });
  assert.equal(page.theme(), "dark");
  page.choose("light");
  assert.equal(page.theme(), "light");
  page.choose("system");
  page.system(false);
  assert.equal(page.theme(), "light");
});

test("LiveView navigation and reinitialization retain preference without duplicate listeners", () => {
  const page = browser({ dark: true });
  page.choose("light");
  page.navigate();
  page.navigate();
  page.run();
  assert.equal(page.theme(), "light");
  assert.equal(page.listeners.get("phx:set-theme").size, 1);
  assert.equal(page.listeners.get("storage").size, 1);
  assert.equal(page.mediaListeners.size, 1);
  page.choose("system");
  page.system(true);
  assert.equal(page.theme(), "dark");
});
