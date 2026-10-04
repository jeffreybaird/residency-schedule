const assert = require("node:assert/strict");
const { test } = require("node:test");
const { pathToFileURL } = require("node:url");
const path = require("node:path");

async function runtime() {
  const { default: hook } = await import(pathToFileURL(path.resolve(__dirname, "../../assets/js/activity_typeahead.mjs")));
  const attrs = new Map([["aria-expanded", "true"], ["aria-activedescendant", "option-1"]]);
  const listeners = new Map();
  const serverEvents = new Map();
  const pushed = [];
  let focused = false;
  const ctx = {
    el: {
      value: "clinic",
      getAttribute: name => attrs.get(name) ?? null,
      addEventListener: (name, callback) => listeners.set(name, callback),
      removeEventListener: (name, callback) => {
        assert.equal(listeners.get(name), callback);
        listeners.delete(name);
      },
      focus: () => { focused = true; }
    },
    pushEvent: (event, params) => pushed.push({ event, params }),
    handleEvent: (event, callback) => serverEvents.set(event, callback)
  };
  hook.mounted.call(ctx);
  return { hook, ctx, attrs, listeners, serverEvents, pushed, focused: () => focused };
}

function key(runtime, name, composing = false) {
  let prevented = false;
  runtime.listeners.get("keydown")({ key: name, isComposing: composing,
    preventDefault: () => { prevented = true; } });
  return prevented;
}

test("navigation and active Enter prevent native submission before dispatch", async () => {
  const state = await runtime();
  for (const name of ["ArrowDown", "ArrowUp", "Enter", "Escape"]) {
    assert.equal(key(state, name), true);
    assert.deepEqual(state.pushed.at(-1), { event: "suggestion-key", params: { key: name } });
  }
  state.attrs.set("aria-expanded", "false");
  assert.equal(key(state, "Enter"), false);
  assert.equal(key(state, "Escape"), false);
  state.attrs.set("aria-expanded", "true");
  state.attrs.delete("aria-activedescendant");
  assert.equal(key(state, "Enter"), false);
});

test("normal typing and composition are untouched and listeners are removed", async () => {
  const state = await runtime();
  assert.equal(key(state, "a"), false);
  assert.equal(key(state, "ArrowDown", true), false);
  assert.equal(key(state, "Enter", true), false);
  assert.deepEqual(state.pushed, []);
  state.hook.destroyed.call(state.ctx);
  assert.equal(state.listeners.has("keydown"), false);
});

test("selected query updates the focused input despite LiveView focused-value preservation", async () => {
  const state = await runtime();
  state.serverEvents.get("activity-query-selected")({ query: "GOG Continuity Clinic PM" });
  assert.equal(state.ctx.el.value, "GOG Continuity Clinic PM");
  assert.equal(state.focused(), true);
});
