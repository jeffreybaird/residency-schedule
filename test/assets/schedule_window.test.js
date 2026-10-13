const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const {test} = require("node:test");

function runtime({width = 948, total = 300, today = -1} = {}) {
  const filename = path.resolve(__dirname, "../../assets/js/schedule_window.js");
  assert.ok(fs.existsSync(filename), "bounded schedule hook module must exist");
  const frames = new Map(), listeners = new Map(), events = new Map(), requests = [];
  const pills = new Map();
  let nextFrame = 0, resize, focused = null;
  const metadata = Array.from({length: total}, (_, i) => [2023 + Math.floor(i / 100), 2023 + Math.floor(i / 100), String(1 + Math.floor(i / 100))]);
  const el = {
    dataset: {slotMetadata: JSON.stringify(metadata), todayIndex: String(today), windowStart: "0", windowCount: "40", slotWidth: "80", nameWidth: "148"},
    scrollLeft: 0, clientWidth: width, isConnected: true,
    getBoundingClientRect: () => ({left: 0, right: el.clientWidth, width: el.clientWidth}),
    addEventListener: (name, callback) => listeners.set(name, callback),
    removeEventListener: (name, callback) => {if (listeners.get(name) === callback) listeners.delete(name);},
    querySelectorAll: () => [], querySelector: selector => pills.get(selector.replace(/^#/, "")) || null,
    focus: () => {focused = "scroll";},
    scrollTo: ({left}) => {el.scrollLeft = left;},
    setAttribute: () => {}
  };
  const document = {getElementById: id => pills.get(id) || null, querySelectorAll: () => [], querySelector: selector => pills.get(selector.replace(/^#/, "")) || null};
  const windowListeners = new Map();
  const window = {addEventListener: (name, callback) => windowListeners.set(name, callback), removeEventListener: name => windowListeners.delete(name)};
  const context = vm.createContext({console, JSON, Math, Number, Map, Set, window, document,
    requestAnimationFrame: callback => {frames.set(++nextFrame, callback); return nextFrame;},
    cancelAnimationFrame: id => frames.delete(id),
    ResizeObserver: class {constructor(callback) {resize = callback;} observe() {} disconnect() {resize = null;}},
    setTimeout, clearTimeout
  });
  const source = fs.readFileSync(filename, "utf8").replace(/export\s+(?=function|const|class)/g, "");
  vm.runInContext(source + "\nglobalThis.factory = createScheduleWindowHook; globalThis.calculate = desiredWindow;", context);
  const reporter = {measureHookEvent: (_hook, view, event, params, reply) => {requests.push({view, event, params: JSON.parse(JSON.stringify(params)), reply});}, invalidateHook: () => {}, cancelHook: () => {}};
  const hook = Object.assign(context.factory(reporter), {el, handleEvent: (name, callback) => {events.set(name, callback); return name;}, removeHandleEvent: name => events.delete(name)});
  function frame() {const pending = [...frames.values()]; frames.clear(); pending.forEach(callback => callback());}
  function ack(index = requests.length - 1) {
    const request = requests[index];
    el.dataset.windowStart = String(request.params.start);
    el.dataset.windowCount = String(request.params.count);
    hook.updated?.();
    request.reply?.({start: request.params.start, count: request.params.count});
  }
  hook.mounted(); frame();
  if (requests.length) {ack(); frame();}
  return {context, hook, el, requests, listeners, events, frames, frame, ack,
    scroll: value => {el.scrollLeft = value; listeners.get("scroll")?.();},
    resize: value => {el.clientWidth = value; resize?.(); windowListeners.get("resize")?.();},
    focused: () => focused, hasResize: () => resize !== null,
    addPill: id => pills.set(id, {focus: options => {focused = {id, preventScroll: options?.preventScroll};}})};
}

test("index geometry covers mobile and ultrawide visible columns with bounded overscan", () => {
  const page = runtime();
  for (const width of [320, 948, 3840, 7680]) {
    const range = page.context.calculate(8000, width, 1000);
    assert.equal(range.first, 100);
    assert.equal(range.start, 92);
    assert.ok(range.count <= 128);
    assert.ok(range.start + range.count >= 100 + Math.ceil((width - 148) / 80));
  }
  const last = page.context.calculate(999999, 948, 300);
  assert.ok(last.start >= 0 && last.start + last.count === 300);
  assert.ok(last.first >= last.start && last.first < 300);
  const empty = page.context.calculate(0, 948, 0);
  assert.equal(empty.count, 0);
});

test("scroll and resize batch per animation frame with one request in flight and latest range queued", () => {
  const page = runtime();
  const initial = page.requests.length;
  page.scroll(8000); page.scroll(8800); page.scroll(9600);
  assert.equal(page.requests.length, initial);
  page.frame();
  assert.equal(page.requests.length, initial + 1);
  assert.equal(page.requests.at(-1).params.first, 120);
  page.scroll(16000); page.resize(3840); page.frame();
  page.scroll(17600); page.frame();
  assert.equal(page.requests.length, initial + 1);
  page.ack(initial); page.frame();
  assert.equal(page.requests.length, initial + 2);
  assert.equal(page.requests.at(-1).params.first, 220);
  assert.ok(page.requests.at(-1).params.count >= Math.ceil((3840 - 148) / 80));
});

test("patches preserve scroll position and offscreen schedule jumps use complete metadata", () => {
  const page = runtime();
  page.el.scrollLeft = 4321;
  page.hook.updated(); page.frame();
  assert.equal(page.el.scrollLeft, 4321);
  assert.ok(page.events.has("scroll-to-schedule"));
  page.events.get("scroll-to-schedule")({schedule_id: "3"}); page.frame();
  assert.equal(page.el.scrollLeft, 200 * 80);
});

test("focus restoration uses the original viewport index and a reachable fallback", () => {
  const page = runtime();
  assert.ok(page.events.has("restore-schedule-focus"));
  page.el.dataset.windowStart = "79";
  page.events.get("restore-schedule-focus")({cell_id: "removed-origin", index: 87});
  page.hook.updated(); page.frame();
  assert.equal(page.el.scrollLeft, 87 * 80);
  assert.equal(page.focused(), "scroll");
  page.addPill("gantt-pill-original-token");
  page.events.get("restore-schedule-focus")({cell_id: "original-token", index: 87}); page.frame();
  assert.deepEqual(page.focused(), {id: "gantt-pill-original-token", preventScroll: true});
  assert.equal(page.el.scrollLeft, 87 * 80);
  page.el.scrollLeft = 90 * 80;
  page.hook.updated(); page.frame();
  assert.equal(page.el.scrollLeft, 90 * 80);
});

test("viewports beyond the server column cap settle after acknowledgment instead of looping", () => {
  const page = runtime({width: 30000, total: 1000});
  let acknowledged = -1;
  for (let iteration = 0; iteration < 4; iteration++) {
    if (page.requests.length - 1 > acknowledged) {
      acknowledged = page.requests.length - 1;
      page.ack(acknowledged);
    }
    page.frame();
  }
  const settled = page.requests.length;
  for (let iteration = 0; iteration < 5; iteration++) {page.hook.updated(); page.frame();}
  assert.equal(page.requests.length, settled);
  assert.ok(settled <= 2, "oversized viewport must not trigger repeated identical window requests");
  assert.ok(page.requests.every(request => request.params.count <= 128));
});

test("focus waits for restored opener DOM after a close patch rather than focusing fallback prematurely", () => {
  const page = runtime();
  page.el.dataset.windowStart = "200";
  page.el.scrollLeft = 200 * 80;
  page.events.get("restore-schedule-focus")({cell_id: "original-token", index: 87});
  page.frame();
  assert.equal(page.focused(), null);
  page.addPill("gantt-pill-original-token");
  page.el.dataset.windowStart = "79";
  page.hook.updated(); page.frame();
  assert.deepEqual(page.focused(), {id: "gantt-pill-original-token", preventScroll: true});
  assert.equal(page.el.scrollLeft, 87 * 80);
});

test("disconnect, reconnect, and teardown ignore stale replies and release listeners and frames", () => {
  const page = runtime();
  page.scroll(8000); page.frame();
  const stale = page.requests.at(-1).reply;
  page.hook.disconnected();
  const before = page.requests.length;
  stale?.({start: 0, count: 40}); page.frame();
  assert.equal(page.requests.length, before);
  page.hook.reconnected(); page.frame();
  const afterReconnect = page.requests.length;
  stale?.({start: 0, count: 40}); page.frame();
  assert.equal(page.requests.length, afterReconnect);
  page.scroll(18000);
  page.hook.destroyed();
  assert.equal(page.frames.size, 0);
  assert.equal(page.listeners.has("scroll"), false);
  assert.equal(page.hasResize(), false);
  stale?.({}); page.frame();
  assert.equal(page.requests.length, afterReconnect);
});
