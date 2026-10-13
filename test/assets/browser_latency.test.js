const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");
const {test} = require("node:test");

const root = path.resolve(__dirname, "../..");
const filename = path.join(root, "assets/js/browser_latency.js");

function browser({href = "https://schedule.example.test/calendar?resident=PRIVATE", entry = null, rejectFetch = false} = {}) {
  assert.ok(fs.existsSync(filename), "browser latency reporter must exist");
  const context = vm.createContext({URL, WeakMap, Map, Set, Promise, console});
  const source = fs.readFileSync(filename, "utf8").replace(/export\s+(?=function|const|class)/g, "");
  vm.runInContext(source + "\nglobalThis.createReporter = createBrowserLatencyReporter;", context);
  let now = 100;
  const requests = [];
  const location = new URL(href);
  const window = {location};
  const document = {readyState: "complete"};
  const performance = {now: () => now, getEntriesByType: type => type === "navigation" && entry ? [entry] : []};
  const fetch = (url, options) => {
    requests.push({url, ...options, sample: JSON.parse(options.body)});
    return rejectFetch ? Promise.reject(new Error("offline")) : Promise.resolve({ok: true});
  };
  const reporter = context.createReporter({window, document, performance, fetch, csrfToken: "test-csrf"});
  return {reporter, requests, document, window, performance, tick: milliseconds => {now += milliseconds;}};
}

function element(view = "calendar") {
  return {isConnected: true, closest: selector => selector === "[data-latency-view]" ? {dataset: {latencyView: view}} : null};
}

test("navigation measures browser elapsed time and posts only bounded fields with CSRF", () => {
  const page = browser();
  const detail = {kind: "redirect", to: "/schedule?token=PRIVATE", event: "PRIVATE"};
  page.reporter.start(detail);
  page.tick(2134.25);
  page.reporter.stop(detail);
  assert.equal(page.requests.length, 1);
  const request = page.requests[0];
  assert.equal(request.url, "/observability/browser-latency");
  assert.deepEqual(request.sample, {view: "schedule", operation: "navigate", duration_ms: 2134.25});
  assert.equal(request.method, "POST");
  assert.equal(request.credentials, "same-origin");
  assert.equal(request.headers["x-csrf-token"], "test-csrf");
  assert.equal(request.headers["content-type"], "application/json");
  assert.equal(request.headers.accept, "text/html");
  assert.ok(!request.body.includes("PRIVATE"));
});

test("initial and patch operations classify both calendar routes and schedule", () => {
  const page = browser();
  for (const [kind, to, view] of [["initial", "/", "calendar"], ["patch", "/calendar?date=PRIVATE", "calendar"], ["patch", "/schedule", "schedule"]]) {
    const detail = {kind, to};
    page.reporter.start(detail); page.tick(10); page.reporter.stop(detail);
    assert.deepEqual(page.requests.at(-1).sample, {view, operation: kind, duration_ms: 10});
  }
});

test("overlapping events on one target pair by detail identity; duplicate or unmatched stops emit nothing", () => {
  const page = browser();
  const target = element();
  const first = {kind: "element", target};
  const second = {kind: "element", target};
  page.reporter.start(first); page.tick(20); page.reporter.start(second); page.tick(30);
  page.reporter.stop(second); page.tick(40); page.reporter.stop(first);
  page.reporter.stop(first); page.reporter.stop({kind: "element", target});
  assert.deepEqual(page.requests.map(r => r.sample.duration_ms), [30, 90]);
  assert.ok(page.requests.every(r => r.sample.view === "calendar" && r.sample.operation === "event"));
});

test("unsupported origins, paths, kinds, and elements cannot send measurements", () => {
  const page = browser();
  for (const detail of [null, {}, {kind: "redirect", to: "https://evil.test/calendar"}, {kind: "patch", to: "/residents/PRIVATE"}, {kind: "unknown", to: "/calendar"}, {kind: "element", target: element("private")}, {kind: "element", target: null}]) {
    page.reporter.start(detail); page.tick(1); page.reporter.stop(detail);
  }
  assert.equal(page.requests.length, 0);
});

test("errors, expired operations, destruction and negative clocks discard pending requests", () => {
  const page = browser();
  const detail = {kind: "patch", to: "/calendar"};
  page.reporter.start(detail); page.tick(10); page.reporter.start({kind: "error", to: "/calendar"}); page.reporter.stop(detail);
  page.reporter.start(detail); page.tick(60001); page.reporter.stop(detail);
  page.reporter.start(detail); page.tick(-1); page.reporter.stop(detail);
  page.reporter.start(detail); page.reporter.destroy(); page.tick(10); page.reporter.stop(detail);
  page.reporter.start({kind: "patch", to: "/calendar"});
  assert.equal(page.requests.length, 0);
});

test("bounded pending requests still admit fresh operations after stale requests expire", () => {
  const page = browser();
  const details = Array.from({length: 1000}, () => ({kind: "patch", to: "/calendar"}));
  details.forEach(detail => page.reporter.start(detail));
  page.tick(5);
  details.forEach(detail => page.reporter.stop(detail));
  assert.ok(page.requests.length <= 64);
  assert.ok(page.requests.length > 0);
  // Leave an entire capacity of operations without stop events, as on disconnect.
  details.forEach(detail => page.reporter.start(detail));
  page.tick(60001);
  const fresh = {kind: "patch", to: "/schedule"};
  page.reporter.start(fresh); page.tick(11); page.reporter.stop(fresh);
  assert.deepEqual(page.requests.at(-1).sample, {view: "schedule", operation: "patch", duration_ms: 11});
});

test("hook reply timing preserves callback operation and rejects late or duplicate replies", () => {
  const page = browser();
  const replies = [];
  const hook = {el: element(), pushEvent: (name, params, callback) => replies.push({name, params, callback})};
  page.reporter.measureHookEvent(hook, "calendar", "restore_prefs", {resident: "PRIVATE"});
  assert.equal(replies[0].name, "restore_prefs");
  assert.deepEqual(replies[0].params, {resident: "PRIVATE"});
  page.tick(1350); replies[0].callback({ok: true}); replies[0].callback({ok: true});
  assert.deepEqual(page.requests[0].sample, {view: "calendar", operation: "event", duration_ms: 1350});
  page.reporter.measureHookEvent(hook, "calendar", "next", {});
  page.reporter.cancelHook(hook); page.tick(10); replies[1].callback({});
  assert.equal(page.requests.length, 1);
  page.reporter.measureHookEvent(hook, "calendar", "next", {});
  page.tick(15); replies[2].callback({});
  assert.equal(page.requests.length, 2);
  page.reporter.measureHookEvent(hook, "calendar", "next", {});
  page.reporter.clear(); replies[3].callback({});
  page.reporter.measureHookEvent(hook, "calendar", "next", {});
  hook.el.isConnected = false; replies[4].callback({});
  assert.equal(page.requests.length, 2);
  assert.ok(page.requests.every(r => !r.body.includes("PRIVATE") && !r.body.includes("restore_prefs")));
});

test("full document timing emits once only after navigation load completes", () => {
  const entry = {duration: 0, loadEventEnd: 0};
  const page = browser({entry});
  page.reporter.reportPageLoad();
  assert.equal(page.requests.length, 0);
  entry.duration = 4523; entry.loadEventEnd = 4523;
  page.reporter.reportPageLoad(); page.reporter.reportPageLoad();
  assert.deepEqual(page.requests.map(r => r.sample), [{view: "calendar", operation: "page_load", duration_ms: 4523}]);
});

test("deferred full document timing keeps the original page attribution after LiveView navigation", () => {
  const page = browser({entry: {duration: 4321, loadEventEnd: 4321}});
  page.window.location.href = "https://schedule.example.test/schedule";
  page.reporter.reportPageLoad();
  assert.deepEqual(page.requests.map(r => r.sample), [{view: "calendar", operation: "page_load", duration_ms: 4321}]);
});

test("disabled performance clocks and failed transport do not affect request producers", async () => {
  const page = browser({rejectFetch: true});
  const detail = {kind: "patch", to: "/calendar"};
  assert.doesNotThrow(() => {page.reporter.start(detail); page.tick(5); page.reporter.stop(detail);});
  await new Promise(resolve => setImmediate(resolve));
  page.performance.now = undefined;
  assert.doesNotThrow(() => {page.reporter.start(detail); page.reporter.stop(detail);});
  assert.equal(page.requests.length, 1);
});
