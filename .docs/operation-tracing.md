# Calendar, schedule, and resident operation traces

Operation tracing is opt-in through the existing `OTEL_ENABLED` configuration.
It uses the existing named OpenTelemetry provider and bounded asynchronous OTLP
exporter. It does not send collector requests synchronously during navigation.

## Trace contract

An `HTTP request` server span covers the endpoint call. Calendar, schedule, and resident
static `LiveView mount` and `LiveView handle_params` spans are children of that
request. Connected LiveView callbacks have separate operation roots when no
parent operation exists. Names are fixed: `LiveView mount`,
`LiveView handle_params`, `LiveView handle_event`, and `LiveView render`.
Attributes identify `view` (`calendar`, `schedule`, or `resident`), `operation`, and
`lifecycle` (`static` or `connected`). Browser timing metrics remain separate;
these traces do not claim browser-to-server navigation correlation.
Each locally rooted operation begins a fresh trace; incoming `traceparent`
headers or an unrelated caller span are not used to invent a parent. The caller's
existing OpenTelemetry context is restored when the operation ends.

The endpoint wrapper also covers early returns, including static assets, with
the same generic HTTP span. Existing completion logs still follow endpoint
completion telemetry and are not duplicated for these early returns.

Phoenix emits render telemetry for connected diff rendering. Static rendering
is part of the HTTP request's remaining time, not a separately measured render
span. Returning a lazy HEEx rendered structure would not measure HTML rendering.

Fixed phase spans separate schedule loading, rotation projection, resident
loading, slot construction, row construction, and cell construction. Calendar
phases separate projection, activities, overrides, filter options, and building
view data. Each phase wraps a collection operation, never an individual cell or
database query. Numeric result counts use only fixed `app.*.count` keys.
Resident phases are `resident.load`, `resident.career`, `resident.project`, and
`resident.coworkers`. The project phase loads one academic-year appearance using
complete schedule evidence; its name never includes a resident or schedule ID.
Coworkers are loaded when that tab is first selected, so that phase is absent
from the default resident mount. Resident callbacks use generic operation and
database diagnostics; schedule-specific render flags are not applied to them.
The fixed resident view is also available on LiveView duration metrics. Browser
latency ingestion retains its existing calendar/schedule contract.
Schedule `app.residents.count` counts loaded schedule-resident records;
`app.rows.count` counts unified resident rows; `app.slots.count` counts combined
date slots; and `app.cells.count` counts rendered grouped cells after adjacent
slots are merged. `app.results.count` counts projection or loaded collection
results. The `schedule.compare` phase wraps the effective-schedule comparison
harness; its `app.mismatches.count` is the sum of differing days and differing
calendar events, never the differences themselves. These counts describe work
size without exposing record identities.

Database diagnostics aggregate query count and query, queue, decode, and total
durations in milliseconds. They include the current process and Ecto parallel
preloads propagated through Ecto's supported `on_preloader_spawn` hook, marked
by `db.query.coverage=current_process_and_preloads`. An explicit caller-supplied
`on_preloader_spawn` option takes precedence over the tracing default; those
custom preload workers are excluded unless they invoke the tracing callback.
Unrelated tasks and other processes are excluded. Every active ancestor includes its descendants' database
work; do not add ancestor and child totals together. Parallel query durations
are sums of work and can exceed the span's elapsed wall time. Total database
time overlaps its query/queue/decode components; it is not an additional cost.

Each operation tree permits at most 128 spans, including its root. The root's
`app.spans.dropped` reports omitted descendants. Each connected callback begins
a fresh budget. Span attributes are capped at 64, values at 64 characters;
events and links remain disabled. Exceptions set sanitized error status while
preserving application exceptions and restoring the caller's tracing context.

## Reading a slow trace

Compare schedule projection/resident-loading phases with slot/row/cell phases.
Large database totals indicate query work; large queue totals indicate waiting
for a connection. Long phases with little database time point toward application
processing. This is attribution, not proof of a particular CPU bottleneck;
profiling remains useful before optimizing.

For a resident page, compare `resident.project` work inside `resident.career`
with the connected render span. Career content and statistics span every
appearance; a long mount does not by itself imply that the resident table needs
windowing. A first coworkers-tab selection intentionally includes its data load;
later selections reuse that LiveView's already-loaded result, including an empty
result.

Connected render time covers the server's render/diff work. Browser metrics
include additional transport and client work. Differences between them cannot
be assigned to a particular request without browser trace correlation.

No resident data, names, identifiers, SQL or parameters, URLs, headers, request
or event payloads, arbitrary event labels, exception messages, or stacktraces
are exported. Existing fixed HTTP completion logs and aggregate metrics remain.
Global SDK span limits also affect any other provider in the same VM.
