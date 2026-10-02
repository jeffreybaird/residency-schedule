const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const { test } = require("node:test");

// The runner may supply a pristine baseline file for authoritative red evidence.
const filename = process.env.APP_JS_UNDER_TEST || path.resolve(__dirname, "../../assets/js/app.js");
const source = fs.readFileSync(filename, "utf8");
const yearTracker = source.slice(source.indexOf("Hooks.YearTracker ="), source.indexOf("// ResidentDrag:"));
const builderHelpers = source.slice(source.indexOf("function checkAllDuplicateNames()"), source.indexOf("Hooks.ResidentDrag ="));

function element(dataset = {}) {
  const classes = new Set();
  const attributes = new Map();
  return {
    dataset, classes, attributes, style: {},
    classList: {
      add: (...values) => values.forEach(value => classes.add(value)),
      remove: (...values) => values.forEach(value => classes.delete(value)),
      toggle: (value, present) => present ? classes.add(value) : classes.delete(value)
    },
    setAttribute: (key, value) => attributes.set(key, value),
    removeAttribute: key => attributes.delete(key)
  };
}

function runtime(nodes) {
  const context = vm.createContext({ Hooks: {}, window: {}, document: {
    querySelectorAll: selector => {
      if (selector === "[data-schedule-pill]") return nodes.pills || [];
      if (selector.includes("input[type='text']")) return nodes.inputs || [];
      if (selector === "[data-res-year]") return nodes.cells || [];
      const year = selector.match(/data-res-year="([^"]+)"/)?.[1];
      return (nodes.cells || []).filter(cell => cell.dataset.resYear === year);
    }
  }});
  vm.runInContext(yearTracker + "\n" + builderHelpers, context);
  return context;
}

test("active schedule pills remove inactive dark styles and restore them when scrolling away", () => {
  const pills = [element({ schedulePill: "one" }), element({ schedulePill: "two" })];
  const context = runtime({ pills });
  let active = "one";
  const hook = {
    stickyWidth: 148,
    el: {
      getBoundingClientRect: () => ({ left: 0 }),
      querySelectorAll: () => [{ dataset: { scheduleId: active }, getBoundingClientRect: () => ({ right: 400 }) }]
    }
  };
  context.Hooks.YearTracker.updateActivePill.call(hook);
  assert.ok(pills[0].classes.has("bg-blue-600"));
  assert.ok(pills[0].classes.has("text-white"));
  assert.ok(pills[1].classes.has("dark:bg-gray-800"));
  assert.ok(pills[1].classes.has("dark:text-gray-200"));
  active = "two";
  context.Hooks.YearTracker.updateActivePill.call(hook);
  assert.ok(pills[0].classes.has("dark:bg-gray-800"));
  assert.ok(pills[0].classes.has("dark:text-gray-200"));
  assert.ok(!pills[1].classes.has("dark:bg-gray-800"));
  assert.ok(!pills[1].classes.has("dark:text-gray-200"));
});

test("duplicate names switch to dark error text and recover neutral text after correction", () => {
  const inputs = [element(), element(), element()];
  inputs[0].value = " Briar ";
  inputs[1].value = "briar";
  inputs[2].value = "";
  const context = runtime({ inputs });
  context.checkAllDuplicateNames();
  for (const input of inputs.slice(0, 2)) {
    assert.ok(input.classes.has("dark:text-red-300"));
    assert.ok(!input.classes.has("dark:text-gray-200"));
    assert.equal(input.attributes.get("title"), "Name must be unique");
  }
  assert.ok(inputs[2].classes.has("dark:text-gray-200"));
  inputs[1].value = "Cedar";
  context.checkAllDuplicateNames();
  for (const input of inputs) {
    assert.ok(!input.classes.has("dark:text-red-300"));
    assert.ok(input.classes.has("dark:text-gray-200"));
    assert.ok(input.classes.has("dark:hover:border-gray-600"));
    assert.equal(input.attributes.has("title"), false);
  }
});

for (const hasError of [false, true]) {
  test(`drag preview has ${hasError ? "error" : "normal"} dark highlight and cleans up after drop`, () => {
    const cells = [0, 1, 2].map(index => {
      const cell = element({ resYear: "4", resIdx: String(index), hasError: String(hasError) });
      cell.offsetHeight = 24;
      cell.inner = element();
      cell.querySelector = () => cell.inner;
      return cell;
    });
    const context = runtime({ cells });
    context.window._residentDragSrc = cells[0];
    context.residentDragApplyPreview(cells[0], cells[2]);
    const highlight = hasError ? "dark:bg-red-950" : "dark:bg-blue-950";
    assert.ok(cells[2].classes.has(highlight));
    assert.equal(cells[1].inner.style.transform, "translateY(-24px)");
    context.residentDragClearPreview();
    for (const cell of cells) {
      assert.ok(!cell.classes.has("dark:bg-blue-950"));
      assert.ok(!cell.classes.has("dark:bg-red-950"));
      assert.ok(!cell.classes.has("ring-2"));
    }
    assert.equal(cells[1].inner.style.transform, "");
    context.residentDragApplyPreview(cells[2], cells[0]);
    assert.ok(cells[0].classes.has(highlight));
    assert.equal(cells[1].inner.style.transform, "translateY(24px)");
    context.residentDragClearPreview();
    assert.ok(!cells[0].classes.has(highlight));
  });
}
