# LiveView latency metrics verification

Verified October 12, 2026. Calendar and schedule LiveView operations now export
server duration histograms through the existing OTLP metrics reporter:

- `phoenix.live_view.mount.stop.duration`
- `phoenix.live_view.handle_params.stop.duration`
- `phoenix.live_view.handle_event.stop.duration`
- `phoenix.live_view.render.stop.duration`

Each histogram uses milliseconds and exactly one attribute: `view=calendar` or
`view=schedule`. Other views and malformed metadata are excluded. Existing HTTP,
database and VM metrics remain tagless. Histogram bounds are 1, 5, 10, 25, 50,
100, 250, 500, 1000 and 5000 ms, with an overflow bucket for slower operations.
The reporter cap is 32 series; server and browser metrics together have 29
possible series, exercised together by the ingestion transport test.

Use these names and the `view` attribute in OTel Hub to distinguish callback
duration from render duration. These are server operation timings, not browser
round-trip latency; network time, browser rendering and queue wait are outside
these spans. Completion events are measured; exception events are not. Export
remains opt-in and best effort. Production delivery was not checked or deployed.

## Accepted contract and evidence

The spec writer wrote the tests, the runner recorded red, the independent
reviewer accepted the contract, and the implementer changed source. The reviewer
then independently accepted the implementation and an alias-only Credo correction.

Final accepted SHA256 hashes:

- `test/residency_schedule/observability_test.exs`:
  `ce0c13646f5fdf1a02e3ab848d2f2dd303b60e454de9a2a7a96c699bc6d0af06`
- `test/residency_schedule_web/observability_live_view_test.exs`:
  `ded007ceccfda2ca8cda7f346baa6f0cfe7a998cd16f5e4e1a26ace0f10c30e6`

Before implementation, targeted tests failed with 6 tests, 3 failures, seed
238741, exit 2: missing definitions and missing decoded OTLP LiveView metrics.
Evidence: `/tmp/liveview-latency-red.log`. Final targeted verification includes
the transport and registered doctest modules: 6 doctests, 11 tests, 0 failures,
seed 238741. Evidence: `/tmp/liveview-latency-green-final.log`.

The real LiveView integration test mounts authenticated calendar and schedule
views, performs patches and filter events, and verifies all four operations in
decoded OTLP requests received by a local HTTP collector. Deterministic telemetry
tests verify 12 ms and 5500 ms values, bucket counts, all 19 series, sensitive-data
exclusion and fixed attributes.

Source and test owners ran scoped `mix format --force` before verification.
The runner's read-only checks passed:

- `mix test --seed 238741`: 205 doctests, 1556 tests, 0 failures;
  `/tmp/liveview-latency-full-test.log`.
- `MIX_ENV=test mix compile --warnings-as-errors`.
- `MIX_ENV=test mix deps.unlock --check-unused`.
- `MIX_ENV=test mix format --check-formatted`.
- `MIX_ENV=test mix credo --strict`: no issues after the reviewed alias correction.
- `git diff --check` and final accepted-test hash comparison.

The final alias correction was followed by targeted tests, Credo, formatting,
diff and hash checks; assertions and runtime behavior were unchanged. Final
summary: `/tmp/liveview-latency-final-check-results.json`. Mix required native
escalation because the sandbox blocked its local PubSub TCP socket.

Fresh security results and pre-existing local OTP findings are documented in
[the security review](liveview-latency-security-review.md). No commits or
deployment were performed.

## Browser measurements

`browser.live_view.round_trip.duration` records elapsed browser milliseconds
with fixed `view=calendar|schedule` and `operation` attributes:

- `initial`: initial LiveView WebSocket join through the resulting DOM update.
- `patch`: LiveView URL patch through the resulting DOM update.
- `navigate`: LiveView navigation through the resulting DOM update.
- `event`: marked controls or measured public hook replies through their DOM update.
- `page_load`: original document Navigation Timing duration through load completion.

Navigation can include a nested initial join; those remain separate operation
series and must not be summed as independent requests. LiveView stops precede
browser paint. Document timing is separate from LiveView join timing. Browser
samples cover successful completions lasting at most 60 seconds; errors,
disconnects, expired starts and duplicate stops are discarded. The pending set
is bounded to 64 entries. Browsers without a monotonic Performance clock do not
report. Full-document labels retain their original view across live navigation.

The browser sends only a fixed view, fixed operation and numeric duration to
`POST /observability/browser-latency`. Session authentication and CSRF protection
apply. Strict field validation rejects unknown fields, labels, negative,
nonnumeric and greater-than-60-second durations. These are client-reported
measurements, not a trusted accounting source. Collector credentials stay on
the server; URLs, event names and application parameters do not enter the metric.
The reporting fetch is outside browser timing and cannot recursively report
itself; it remains an ordinary request in the existing aggregate HTTP metrics.

Browser behavior used the same delegated workflow. Initial red: Node 9 tests,
9 failures (missing reporter); backend 6 tests, 6 failures (missing ingestion
and control flags). An added document-attribution regression then demonstrated
9 passing Node tests and 1 failure before the source correction. Final accepted
browser contract hashes:

- `test/assets/browser_latency.test.js`:
  `bbe6b47ece778e7671f7b45a6ab316979aeebe31d3fe1bfb9445c20f9e9fc19c`
- `test/residency_schedule_web/controllers/browser_latency_controller_test.exs`:
  `84d6abf8d1c89c3c5eed9a86210928f538593141d84f25fad1aee96375757af9`

The reviewer accepted deterministic seeding of optional database `idle_time`
without changing the 29-series assertion, and numeric-underscore corrections
without changing values. Existing calendar preference tests were preserved by
moving the new loading flag before their original contiguous attributes.

Initial browser verification, seed 238741 (superseded by the controls correction below):

- Focused: 9 doctests, 59 tests, 0 failures, including existing calendar tests.
- Full suite: 208 doctests, 1563 tests, 0 failures.
- Node asset regression suite: 30 tests, 0 failures (10 browser timing tests).
- Compile warnings-as-errors, formatting, unused dependencies, strict Credo,
  diff checks and accepted-test hashes all pass.

Evidence: `/tmp/browser-latency-red-{node,mix}.log`,
`/tmp/browser-latency-initial-url-red-node.log`,
`/tmp/browser-latency-green-final-mix.log`,
`/tmp/browser-latency-full-test-final.log`, and
`/tmp/browser-latency-final-check-results.json`.

Independent audit review found only ambiguous formatter overlap entries:
the implementer owned app/calendar/schedule source changes, while the spec
writer owned observability test changes. Correction commands were scoped to
their owners' paths; no exclusive ownership violation was found.

## Loaded browser smoke test

The runner built the actual application assets and started an isolated synthetic
demo database and local OTLP collector on loopback. Existing local services were
preserved; the application used port 4013. The parent operated native Chrome to
load calendar and navigate to schedule. The independent
reviewer inspected decoded OTLP output in `/tmp/browser-latency-qa-points.jsonl`:

| View | Browser operation | Example duration (ms) |
| --- | --- | ---: |
| calendar | initial | 1062.0 |
| calendar | page_load | 1105.9 |
| calendar | event | 222.4 |
| schedule | navigate | 357.3 |
| schedule | initial | 528.8 |
| schedule | event | 16.4 |

Initial browser samples reached the local collector with unit `ms`, numeric
durations and only the fixed view/operation attributes. Corresponding server
mount, callback and render histograms remained separate. This initial smoke test confirms
navigation and public-hook wiring and local transport; it is not a production delivery test
or a performance benchmark. The disposable QA service and database are removed
after the smoke test.

The parent then found a blocking controls defect: clicking calendar Next and
schedule R2 generated server metrics without browser event metrics. Earlier
browser event samples came from preference restoration and year-tracker hooks.
The installed LiveView client does not consume a `phx-page-loading` HTML
attribute. Its public API is `JS.push(event, page_loading: true)`. Final review
was revoked until a renewed contract, source correction and explicit
before/after control-click verification in the loaded browser passed.

## Supported controls correction and final verification

All 27 calendar/schedule click, change and submit bindings now use public
`JS.push(original_event, page_loading: true)`. Original `phx-value-*` parameters
remain unchanged. Stable control IDs and fixed `data-action` attributes provide
selectors independently of the encoded JS command. The spec writer migrated
existing selectors without changing behavior assertions. The new contract
decodes every rendered page-owned binding, including filter panels, modal and
administrator delete form, and requires the original event with
`page_loading: true`. Shared layout controls stay outside this page scope.

Renewed red: 1 doctest, 7 tests, 2 expected failures before source correction;
`/tmp/browser-latency-js-push-red.log`. The reviewer accepted all 13 changed test
files and subsequent descendant-query and equivalent nonempty-predicate
corrections. Accepted hashes were compared after implementation using
`/tmp/browser-latency-supported-controls-accepted-hashes.txt`.

Final green, seed 238741:

- Targeted calendar/schedule contracts: 2 doctests, 202 tests, 0 failures.
- Full suite: **208 doctests, 1564 tests, 0 failures**.
- Node asset regressions: **30 tests, 0 failures**.
- After the final equivalent style correction: controller 1 doctest, 7 tests,
  0 failures; strict Credo, formatting, diff and all 13 accepted hashes pass.
- Compile warnings-as-errors and unused-dependency checks pass.

Evidence: `/tmp/browser-latency-js-push-green-final.log`,
`/tmp/browser-latency-js-push-full-test.log`, and
`/tmp/browser-latency-js-push-final-check-results.json`.

The runner rebuilt actual assets and restarted the isolated QA service with a
fresh collector artifact. The parent then proved individual native Chrome
controls independently of background hooks:

| Control | Browser event count before | Count after | New duration (ms) | Observed UI result |
| --- | ---: | ---: | ---: | --- |
| calendar Next | 1 | 2 | 125.2 | October changed to November 2026 |
| schedule R2 | 1 | 2 | 235.4 | Other resident-year rows disappeared |

Baseline samples were preference restoration (40.6 ms) and YearTracker (3.5 ms).
Each click added its own decoded OTLP browser event sample with fixed view and
operation attributes. Navigation, initial join and document-loading samples
also reached the collector. Fresh evidence: `/tmp/browser-latency-qa-points.jsonl`;
the earlier artifact showing the missing controls is preserved separately at
`/tmp/browser-latency-qa-before-js-push-points.jsonl`. The parent closed the QA tab
and restored the user's original tab after verification.

The runner recorded before/after counts and decoded values in
`/tmp/browser-latency-native-qa-proof.json`, stopped only its QA session and
removed only `residency_schedule_browser_latency_qa_20261012`; both cleanup
commands exited 0. User services remained untouched. A later ambiguous runner
audit entry overlapped the spec writer's controller style correction; the spec
writer owned that test edit, and the runner's command was read-only.
