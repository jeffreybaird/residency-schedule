# Render diagnostics verification

## Contract and red evidence

Independent review accepted the test contract before source implementation.
The initial authoritative run recorded **21 tests, 16 expected failures** for
missing diagnostic APIs, with five existing checks passing
(`/tmp/render-diagnostics-red.log`). The profiler fixture was then corrected
to provide a valid user and explicitly load installed OTP tools for the
pre-existing-profiler test. Its final red run had three expected missing-helper
failures (`/tmp/render-diagnostics-profile-red-tools-final.log`).

Tests decode exported OTLP and exercise real connected LiveViews, native
start/stop metadata, exact V2 protocol parity, preserved V1 transport mappings,
encode-once success/error behavior, one-use correlation, explicitly uncorrelated
initial joins, deployment metadata validation, and local profile cleanup.

Additional independently reviewed regressions cover no-op events followed by
internal renders, render exceptions, malformed diagnostics that must not detach
the telemetry handler, and encoding diagnostics that must neither retry the
encoder nor replace its result/exception. The approved causal refinement uses
`unknown` for info/async callbacks because native completion evidence is absent.
These were explicit contract refinements, not assertions weakened to pass.

A maximum-population OTLP test requires exactly **34 render attributes**,
including all existing DB fields, eight changed-assign flags, process snapshots,
counts, event cause, and deployment SHA. The configured 64-attribute cap must not
truncate this set; events and links remain empty. Privacy sentinel checks cover
payloads and arbitrary assign/event names.

## Reproduction and scope

`test/support/benchmarks/render_diagnostics.exs` reuses the guarded synthetic
four-year fixture. It explicitly invokes the real renderer, lazy diff evaluation,
after-render hooks, and final private-diff/cleanup stages. Optional eprof selects
only the caller process and does not trace spawned processes. Profiling is not
started during normal application operation and production compilation returns
the disabled result.

Serialization measurements are separate from render timing. Initial join encoding
cannot inherit process-local render context because Phoenix performs it in another
process; its span honestly reports unavailable correlation. Generic V2 encoding
diagnostics cover all LiveViews while detailed render metadata remains limited
to calendar/schedule. No topic/reference identifiers or payload data are exported.

## Accepted hashes

All seven final hashes were independently reviewed and verified by the runner:

| File | SHA-256 |
| --- | --- |
| `test/residency_schedule_web/live_serializer_test.exs` | `d70b865fd2d3a7444f0c944cf123a9552f30780f8ed9e7449b269a1b9c10e147` |
| `test/residency_schedule_web/render_diagnostics_test.exs` | `af5b5215c4e1f98814415cdbd3c2bd1645e94f6509f41025af65b1af90dd2670` |
| `test/residency_schedule_web/local_render_profile_test.exs` | `267e0d2871403622a04460aea97d9b684a945ac05c6d30b055860990618f595d` |
| `test/residency_schedule/observability_test.exs` | `c4741fd1cf8dea4c1587032427f9f678c8bc728190ea711312727ecad2614b20` |
| `test/residency_schedule_web/operation_tracing_test.exs` | `13d852dfc29436ee5b062905c1dd6d497972081cda1615a92a2d6a1c59bc2bbe` |
| `test/support/benchmarks/render_diagnostics.exs` | `7c613daa479e04288d52c46a8a75431621f81e44d21ee9bc265c8fe8a7150e61` |
| `test/support/counting_json.ex` | `bdaec006d355b54db99da0eafbd5cd7ff522c5b170ab6562dcfa3d95261c072f` |

## Profile findings

The runner executed the opt-in profiler against the synthetic four-year fixture.
For its initial render, renderer setup measured 11.28 ms, `Diff.render` 503.87 ms,
after-render hooks 0.0027 ms, and finalization 0.0054 ms. Profiling inflates elapsed
time, so these are diagnostic stage proportions, not a production latency claim.
The initial diff remains approximately 5.26 MB uncompressed.

Leading exclusive eprof shares in that initial run were:

| Function/work | Exclusive share |
| --- | ---: |
| `Phoenix.HTML.Engine.html_escape/5` | 17.56% |
| `Phoenix.HTML.Safe.Integer.to_iodata/1` | 9.30% |
| `Phoenix.LiveView.HTMLEngine.binary_encode/1` | 4.43% |
| `Phoenix.LiveView.Diff.traverse_dynamic` | 4.16% |
| `Phoenix.LiveView.Diff.traverse` | 4.15% |
| Generated schedule header function | 3.14% |
| Generated rotation-cell function | 2.20% |

The synthetic evidence places most measured stage time inside lazy template/diff
evaluation, with HTML conversion and traversal prominent. It does not establish
the cause of a particular production request. Full aggregate evidence is in
`/tmp/render-diagnostics-local-profile.log`.

## Overhead and limits

One thousand metadata start/finish calls took a median 1.666 ms, approximately
1.7 microseconds and 157 reductions per call pair. This isolates metadata work;
it is not the full tracing/export overhead.

Whole-render runs with the telemetry handler attached versus detached had medians
96.5 versus 111.9 ms and approximately 8.84 versus 8.86 million reductions. The
negative difference is noise; it does not demonstrate an improvement or a precise
whole-render overhead estimate. These runs include span handling and are not a
pure metadata comparison.

With observability disabled, the wrapper used 105 versus 91 reductions for a
small message, approximately 0.011 versus 0.008 ms. Large-payload timings were
too sensitive to GC/order effects to attribute a reliable overhead. Native and
wrapped outputs matched exactly, with one encoder call per measurement. The
separate actual encoding median for the large fixture was 114.9 ms and 8.88 million
reductions, outside the render measurement. Evidence:
`/tmp/render-diagnostics-overhead.log`.

## Final verification

- Full suite: **212 doctests, 1,625 tests, zero failures**.
- Focused diagnostics: **35 tests passed**; final doctest check: **11 doctests and
  one test passed**.
- Browser latency: **10 tests passed**.
- Compilation with warnings treated as errors, formatting, unused dependencies,
  and strict Credo all passed. Credo checked 298 files and 2,461 modules/functions
  without issues.
- An isolated VM compiled the production branch of the profile helper, confirmed
  `{:error, :disabled}`, and verified no eprof process started
  (`/tmp/render-diagnostics-production-guard.log`).

Authoritative green logs use `/tmp/render-diagnostics-green-` followed by
`full.log`, `focused.log`, `compile-final.log`, `doctest-final.log`,
`format-final.log`, `credo-final.log`, `deps.log`, and `browser.log`.
The disposable benchmark database was dropped. Independent final review covered
source, accepted tests, privacy budgets, protocol compatibility, profiler cleanup,
deployment wiring, and the audit log. No production profiler or UI change was
introduced.

Fresh security evidence and review limitations are in
[render-diagnostics-security-review.md](render-diagnostics-security-review.md).
