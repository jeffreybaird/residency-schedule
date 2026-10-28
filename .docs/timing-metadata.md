# Timing metadata

This increment is the third additive-schema delivery of Phase 2 in the
[model migration plan](schedule-adapter-release-plan.md), following merged
[PR #91](https://github.com/jeffreybaird/residency-schedule/pull/91). It records
how precisely each saved source occurrence states its time without changing any
assignment, date, label, identity, fingerprint or coverage link. Existing
importers, projections, calendar exports and assistant queries remain
authoritative and do not consult this representation.

## Precision outcomes

Every saved assignment has a literal source date. Most say nothing more. The
stored representation keeps those facts apart:

| Precision | Meaning | Required fields |
| --- | --- | --- |
| `exact` | The source stated a start and end instant. | `starts_at`, `ends_at`, `time_zone`; `starts_at < ends_at` |
| `period` | The source stated only a part of the day. | `period` in `AM`, `PM`, `Day`, `Night`; no instants |
| `date_only` | The source stated only the date. | no period, no instants |

The period labels are the closed set already stored by the QGenda commit path.
A period label never establishes hours: `Night` records that the source said
night on the literal `source_date`; it does not record 18:00 or an end on the
next morning. Existing readers continue to apply the Strong night-boundary
projection, the Saturday Highland gap rule, the Friday Strong correction and the
calendar export's fixed rendering hours with their current context. None of
those rules is applied by this increment, and no date is adjusted a second time.

No `exact` timing is backfilled. No current adapter supplies instants, and
task names such as `SMH GYN R2 Day` or `HH Nights 3rd Call` are not evidence
of hours. The `exact` precision exists so that the schema, the pure
interpretation and the constraints are already correct when a future adapter
supplies real instants; writing them remains later writer work. That writer
must store instants normalized to UTC (the schema's `utc_datetime` fields) and
record the source zone in `time_zone`.

## Representation

`activity_source_timings` holds one row per saved source occurrence:

- `original_source_id` (unique, positive) with nullable `activity_source_id`
  that is set null on live source deletion and must equal the original ID while
  live. Deleting activities, batches or academic years is not blocked.
- `namespace` in `csv`/`qgenda`, taken from the batch's `source_kind`.
- `source_date`: the literal stored activity date, never adjusted.
- `precision`, `period`, `starts_at`, `ends_at` and `time_zone`, constrained
  as in the table above. Instants are `timestamp with time zone`; `time_zone`
  is an IANA name of at most 64 bytes recorded only with `exact` precision.
- `source_snapshot` (date, raw task, stored period) and `input_digest` so later
  changes to source facts are detected instead of silently reinterpreted.
- `rule_version` (`legacy_timing_v1`), named `policy`
  (`stored_period`, `date_only`, `exact_source`) and `evidence_origin`
  (`legacy_code`, `reviewed`, `custom`).

Rotations stay date-only blocks and receive no new column: their start and end
dates are already literal, and projecting them onto hours remains reader work.

## Pure interpretation

`ResidencySchedule.Timings.interpret/1` is read-only and never touches the
database:

```elixir
alias ResidencySchedule.Timings

{:ok, %{precision: :period, period: "PM"}} =
  Timings.interpret(%{date: ~D[2026-12-30], period: "PM"})

{:ok, %{precision: :date_only}} = Timings.interpret(%{date: ~D[2026-12-30], period: nil})

{:ok, %{precision: :exact}} =
  Timings.interpret(%{
    date: ~D[2026-12-30],
    starts_at: DateTime.new!(~D[2026-12-30], ~T[07:00:00], "America/New_York"),
    ends_at: DateTime.new!(~D[2026-12-30], ~T[17:00:00], "America/New_York")
  })
```

Each result carries `source_date`, `precision`, `period`, `starts_at`,
`ends_at`, `time_zone`, `rule_version` and `policy`. A missing or invalid date,
a period outside the closed set, instants in different zones, an end that is
not after its start, or instants supplied together with a period return a
tagged error (`:invalid_date`, `:unsupported_period`, `:invalid_instants`).
The `exact` result's `time_zone` is the zone of the supplied instants; the
caller supplies `source_date` literally, and the function does not derive it
from the instants.

## Backfill

`Timings.backfill(batch_size: 500)` walks saved source occurrences by stable ID
in batches of 1–1,000 and inserts a missing timing for each from its stored
activity date and stored period only. It rechecks the source row under the
existing write lock before inserting, never updates an existing row, and holds
one transaction per batch, so interrupted work can be rerun.

Counts: `processed` (new rows), `period` and `date_only` (new outcomes),
`unchanged` (legacy rows whose digest still matches the current source facts
and rule version, and every reviewed/custom row, whose evidence is never
reinterpreted) and `conflicting` (legacy rows whose source facts or rules
changed, which are retained for explicit review, plus live sources whose stored
period label is outside the closed set, which receive no row). A completed repeat inserts zero rows. A batch whose source is not
`csv`/`qgenda` returns `{:error, :unsupported_namespace}` and rolls back that
batch; earlier batches remain.

From the installed release, after the reviewed schema is deployed:

```sh
bin/residency_schedule eval 'IO.inspect(ResidencySchedule.Release.backfill_timings())'
```

The call prints `{:ok, counts}`. This document records the operator contract
and local validation only; see the
[verification record](timing-metadata-verification.md). It does not establish
production execution, and the earlier production backfills remain unconfirmed
by repository evidence.

## Delivery boundaries

No source dates, periods, raw tasks, activity identity, rotation records,
import fingerprints, coverage links, notes or calendar event identities are
rewritten. There is no reader or writer cutover, no hour inference and no
management UI. The [snapshot-and-rebuild decision](schedule-adapter-recovery-decision.md)
remains in effect.
