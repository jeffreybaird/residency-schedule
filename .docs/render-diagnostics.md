# Reading render diagnostics

The diagnostics identify which deployed code produced a render, why the render
ran, and how much work was available. They preserve the current UI and do not
reduce the initial grid payload by themselves.

## Deployment and render identity

The deployment workflow writes the checkout's 40-character commit SHA into the
release's `priv/deploy_sha` before asset compilation. At runtime, observability
validates that value and publishes it as resource `service.version` and render
attribute `deployment.sha`. An absent or invalid value becomes `unknown`; no
arbitrary environment value is exported. This works with cached compilation and
does not assume the deployed service inherits GitHub Actions environment variables.

`app.render.sequence` counts renders in that LiveView process.
`app.render.initial` distinguishes its first render. `app.render.force` and
`app.render.changed` preserve Phoenix's native start metadata; force does not
mean initial. A sequence is local to the process, not a global request identifier.

`app.render.trigger` is one of `initial`, `params`, `event`, or `unknown`.
Event names come from a code-defined per-view allowlist; unknown events
become `_OTHER`. Callback hooks reset pending attribution, and render start
consumes it. No-op event/parameter completion clears unused attribution.
Info/async hooks clear the cause to `unknown`: Phoenix supplies no corresponding
completion telemetry to prove that a later render was caused by that callback.
Raw event arguments and payloads are never exported.

Eight `app.render.changed.*` booleans capture the change map at render **start**:
`name_col_px`, `visible_resident_groups`, `all_slots`, `rotation_modal`,
`filter_year`, `viewed_aca_year`, `schedules`, and `unified_residents`. A nil change
map denotes full evaluation. Stop metadata is unsuitable for this purpose because
Phoenix clears the change map before emitting the stop event.

## Workload and process measurements

`app.rows.count`, `app.slots.count`, `app.cells.count`, and `app.cohorts.count`
describe the available schedule workload. They are precomputed when visible
groups change. They do **not** count cells actually visited during this diff:
unchanged groups can be skipped even when their available cell count is large.

`app.process.reductions.delta` measures BEAM process reductions during the render.
It is not CPU time. `app.process.memory.before_bytes` and `after_bytes` are process
memory snapshots, not allocated bytes or peak memory. Mailbox before/after counts
are queue-length snapshots, not wait time. These measurements help distinguish
large computation from other delays without inspecting messages or heap contents.

Existing aggregate database diagnostics remain. A render with zero database
queries can still spend substantial time evaluating lazy HEEx and computing its
diff. Start/stop measurements cover the native render span, which includes
`Renderer.to_rendered`, `Diff.render`, and after-render hooks.

## Serialization

The V2 serializer delegates encoding exactly once and measures that call. A
separate `LiveView encode` span records duration and the byte length of the
existing encoded iodata. Bytes are **before compression**; they are not the
compressed wire size or browser patch cost. Incoming decoding and broadcast
fastlane behavior remain compatible, and both transports retain V1 negotiation.
Generic encoding diagnostics cover all LiveView V2 messages, including views
outside calendar/schedule. Uncorrelated spans omit the view label. Render
diagnostics themselves remain limited to calendar and schedule.

`app.encode.duration_ms` isolates the underlying encoder call. The enclosing
encode span also includes the small cost of measurement and attribute handling;
neither includes network delivery or browser work.

An ordinary diff encoded in the LiveView process can consume a one-use render
context. Its encode span is a follow-on child: encoding occurs after the render
span ends, so its duration is not included in the render duration. Initial join
replies are encoded in another process and report correlation `unavailable`.
They are not falsely attached to a render. No cross-process payload tokens or
unbounded context queue is introduced.

All labels and attribute names are fixed. A fully populated render has at most
34 attributes, including existing database fields and deployment SHA; the SDK
cap is 64 with events and links still disabled. No SQL, resident/session identifiers, names, URLs,
headers, payloads, exception messages, stacktraces, or arbitrary assign keys enter
these diagnostics.

## Local profiling

Use `test/support/benchmarks/render_diagnostics.exs` only with an explicitly named
disposable database. It reuses the guarded synthetic four-year fixture and reports
initial, unchanged, and filtered renders separately:

```
SCHEDULE_BENCHMARK_DATABASE=residency_schedule_cache_bench_<suffix> \
  MIX_ENV=test mix run --no-start test/support/benchmarks/render_diagnostics.exs
```

Create that database beforehand and drop it afterward, including after failure.
Add `RENDER_EPROF=true` to profile the selected local process during these runs.
No profiler starts with the application; production builds disable this helper.
An existing profiler session is not taken over. Owned profiling is stopped even
when rendering fails.

Stage times separate renderer setup, `Diff.render` (including lazy template
evaluation), after-render hooks, and private-diff/cleanup work. This can explain a
reproducible slow render; it cannot retrospectively profile a completed production
trace. No dependency monkey patch or permanent production tracing is installed.
