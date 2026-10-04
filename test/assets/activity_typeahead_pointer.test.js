const assert = require("node:assert/strict");
const { test } = require("node:test");
const { pathToFileURL } = require("node:url");
const path = require("node:path");

test("option pointerdown retains input focus without blocking other targets and cleans up", async () => {
  const { default: hook } = await import(pathToFileURL(path.resolve(__dirname, "../../assets/js/activity_typeahead.mjs")));
  const listeners = new Map();
  const ownOption = {};
  const foreignOption = {};
  const wrapper = {
    addEventListener: (name, callback) => listeners.set(name, callback),
    removeEventListener: (name, callback) => {
      assert.equal(listeners.get(name), callback);
      listeners.delete(name);
    },
    contains: option => option === ownOption
  };
  const context = {
    el: {
      closest: selector => {
        assert.equal(selector, "[data-activity-typeahead]");
        return wrapper;
      },
      addEventListener: () => {},
      removeEventListener: () => {},
      getAttribute: () => null
    },
    handleEvent: () => {},
    pushEvent: () => {}
  };
  hook.mounted.call(context);
  assert.equal(typeof listeners.get("pointerdown"), "function");
  for (const [option, shouldPrevent] of [[ownOption, true], [foreignOption, false], [null, false]]) {
    let prevented = false;
    listeners.get("pointerdown")({
      target: { closest: () => option },
      preventDefault: () => { prevented = true; }
    });
    assert.equal(prevented, shouldPrevent);
  }
  hook.destroyed.call(context);
  assert.equal(listeners.has("pointerdown"), false);
});
