# OTel Hub histogram investigation handoff

Improve OTel Hub's histogram detail page so an operator can investigate a slow
operation at a particular time. The current page displays only the latest export
interval, even when the selected window includes many older intervals. This is
work item 2 from the Residency Schedule latency investigation on October 13, 2026.
Another agent is implementing operation traces in Residency Schedule separately.

## Ownership and repository

Work in `/Users/jeffreybaird/src/otel_hub`. Read its `AGENTS.md` and applicable
project guidance, inspect local changes, and update from its main branch before
editing. The inspected local revision was `016e13a`; verify the current revision.
Own Hub histogram queries, presentation, tests and documentation. Do not modify
Residency Schedule's tracing implementation or `otlp_shipper` as part of this task.
Follow the target repository's test and agent workflow. This handoff does not
authorize deployment, public release, changes to access controls or production data.

## Evidence and current behavior

Residency Schedule main revision `4754e6f` added LiveView and browser latency
histograms. Its locked versions are `otlp_shipper 0.2.2`, OpenTelemetry SDK `1.7.0`
and API `1.5.0`. The application's instrumentation scope version `0.1.0` shown
in Hub is not the shipper version.

The production trace
`https://elixir-as-inf.diviningdad.com/traces/eecc2c330e07218578a9820d38b23a51`
started at `2026-10-13 12:36:07.165 UTC`, lasted 3.2 seconds and contained only
one span. During investigation, the latest schedule mount histogram interval at
`12:36:22.547 UTC` contained a measurement in `(1000, 5000] ms`; schedule render
contained one in `(500, 1000] ms`. These are nearby aggregate observations, not
a trace-correlated breakdown of that request. A later fast interval hides these
slow observations in the current histogram visualization.

Inspect these source files in Hub:

- `lib/otel_hub/metrics.ex`: `points/1` accepts only gauge/sum kinds;
  `latest_point/1` selects one point; `histogram_buckets/1` formats its buckets.
- `lib/otel_hub_web/live/metric_live/show.ex`: `chart/2` uses `latest_point/1`
  for distributions; the page renders a bar chart of that single point.
- The metric point schema, OTLP ingestion and metric components: follow their
  references from the files above to verify stored data and existing chart APIs.
- `/Users/jeffreybaird/src/otlp_shipper/lib/otlp_shipper/metrics/aggregation.ex`:
  histograms already encode interval start/end, count, bucket counts, explicit
  bounds, min/max and sum when valid, using DELTA temporality.

Residency Schedule exports approximately every five seconds. Existing duration
bounds in milliseconds are `[1, 5, 10, 25, 50, 100, 250, 500, 1000, 5000]`, plus
overflow. Hub cannot recover precision within these buckets or manufacture
individual request timings. Finer producer bounds are a separate coordinated
Residency Schedule change, not a Hub-only fix.

## Required operator experience

1. Select a source, metric, attribute series and time window; inspect historical
   histogram intervals within that window, rather than only the newest point.
2. Show each interval's timestamps, count, sum when present, weighted mean when
   defined, min/max when present and bucket distribution. Display units clearly.
3. Provide a bounded history visualization or table with interval selection, so
   a later fast interval does not obscure an earlier slow interval. Preserve
   accessible tabular access and existing source/window/series filters.
4. If adding a window aggregate, label it distinctly from the selected interval
   and apply correct temporality and bucket compatibility rules.

## Aggregation rules and edge cases

- For compatible DELTA intervals, sum counts, sums and corresponding bucket
  counts. Calculate a mean as total sum divided by total count, not the mean of
  interval means. Do not treat zero count as a measured zero duration.
- Preserve missing sum/min/max as unavailable. A partial set of extrema must
  not silently become a complete window's extrema.
- Never sum cumulative snapshots as though they were delta intervals. Define
  and test cumulative behavior, including resets, or explicitly present those
  intervals without an invalid window aggregate.
- Do not merge different sources, resources/scopes or distinct series merely
  because the metric name matches. Inspect the current series identity and
  ensure any aggregation is semantically compatible.
- Handle changed bucket boundaries without aligning counts by array index.
  Separate incompatible intervals or use a documented mathematically valid
  coarsening. Report missing, malformed and unsupported data honestly.
- Preserve gaps as gaps. Bound queries and rendered points for long windows;
  use deterministic ordering when timestamps match.
- Any percentile derived from buckets is approximate; overflow buckets do not
  establish a finite upper bound. Prefer delivering history and exact supplied
  statistics before adding percentile estimation.

## Acceptance and verification

Use synthetic OTLP fixtures with at least two intervals: an earlier slow interval
and a later fast interval. Both must remain discoverable in the selected window.
Prove source/series isolation, unit preservation, interval selection, empty state,
optional fields, weighted means, temporality handling, changed bounds and bounded
query behavior. Include a case whose incorrect unweighted mean would differ from
the correct result. Existing gauge/sum behavior must retain its contract.

Run the target repository's required tests, formatting, static analysis and fresh
security advisory checks. Verify the rendered page with synthetic data, including
its table and narrow layout. Do not copy production telemetry into public fixtures
or transmit credentials. Deliver the code, test evidence and a concise explanation
of interval versus window statistics and any remaining limitations.

## Coordination with operation tracing

The Residency Schedule agent owns fixed-label operation spans and numeric
diagnostics, with no resident data, SQL text, request URLs, headers or payloads.
Hub already stores and displays parent/child spans and attributes; the histogram
work can proceed independently. It must not claim that aggregate intervals are
correlated with individual traces unless an explicit correlation mechanism is
implemented and verified in a later coordinated change.
