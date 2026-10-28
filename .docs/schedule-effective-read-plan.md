# Plan: Phase 3, compare new effective-schedule reads

Drafted October 28, 2026 from merged `main` after
[PR #93](https://github.com/jeffreybaird/residency-schedule/pull/93), with all
Phase 2 schemas deployed and their backfills
[confirmed complete in production](phase2-production-backfill-record.md).
This plan settles the design decisions Phase 3 needs before its first accepted
test. It implements the Phase 3 row of the
[release plan](schedule-adapter-release-plan.md) and nothing from Phase 4:
users keep receiving existing results throughout.

## Goal

Build one explicit effective-schedule service that computes schedule meaning
from stored records and the Phase 2 representations, then prove it agrees with
every existing consumer before any consumer is switched. The deliverable is
not only the service; it is the comparison evidence and a classified list of
every difference found.

## What the existing reads are today

The survey behind this plan (recorded here so the next context need not
repeat it) found one projection pipeline and several paths around it:

- `Rotations.project_assignments/3` applies, in order, `HighlandPostCall`,
  `StrongNightBoundaries`, `FridayNightFloat` and `ScheduleGaps`, marking
  projected rows with the virtual `source_assignment_date` and `source_tasks`.
  `build_effective_segments/3` then applies coverage (`covered_by`,
  `is_coverage`, `original_resident`), and `effective_day_assignments/2`
  applies it per day. `TaskEquivalence` supplies label matching and the
  Saturday Highland gap rule.
- Consumers: the calendar LiveView (projection in a window, day rows through
  `effective_day_assignments`, month summaries without overrides), the schedule
  grid (`ScheduleCache` over `projected_rotations_for_schedule`), the resident
  page (`resident_schedule_data`, coworker counts and rows), the compare page,
  the assistant and MCP tools (`who_is_on`, `shifts_remaining`,
  `shared_shifts*`, `resident_schedule`, `check_coverage`), duty-hour
  estimates and the iCalendar feeds (`effective_segments_for_resident/person`).
- Paths that bypass the projection: off-coworker rows, the raw rotation lookup
  in `check_coverage`, the SQL `list_co_service_days`, and `search_activities`.
- Known inconsistencies between paths: coverage segments carry the stored
  rotation type rather than the projected one; cross-schedule coverage is not
  visible to gap filling; month summaries ignore overrides; overlapping
  segments on one day resolve by map order in duty-hour estimates.

Calendar event identity depends only on `rotation_type`, segment `start_date`
and, for timed events, the day. Any change to segment splitting changes UIDs.

## Design decisions

### D1. The unit of comparison is the daily duty set, plus calendar identity

Schedule meaning is normalized to one record per person, membership and date:

```text
%{
  person_id, schedule_resident_id, schedule_id, date,
  duties: [%{kind, code, label, status, source_tasks, timing, covered_by_person_id,
             original_person_id, source_assignment_date}],
  off: :blank | :explicit_off | :vacation | :leave
}
```

`kind` is `:rotation`, `:dated_activity`, `:gap_fill` or `:coverage`; `status`
is `:working`, `:covered` or `:off`; `timing` is the Phase 2 precision record
(`date_only`, `period` with its label, or `exact`), never derived hours.
Duties are sorted by a total order so two sets compare by equality.

Daily granularity removes segment-splitting noise from the core comparison.
Segment boundaries still matter for calendar subscribers, so calendar identity
is compared separately as the set of `{uid, dtstart, dtend, summary}` per
person. Consumers that summarize (statistics, matrices, duty hours) are
compared on their outputs, not re-derived.

### D2. One service, built in two steps behind a fixed interface

`ResidencySchedule.EffectiveSchedule` exposes:

- `for_schedule(schedule_id, version)` returning the daily duty sets for every
  membership, with `version` in `:legacy` or `:v2`;
- `for_person(person_id, version)` and `for_date(schedule_id, date, version)`
  derived from it;
- `calendar_events(person_id, version)` returning the identity set in D1.

Step one implements `:legacy` as an adapter over the existing functions
(`projected_rotations_for_schedule`, `build_effective_segments`,
`effective_day_assignments`, `Ical.build_from_segments`) and `:v2` as the same
adapter. The comparison harness therefore starts at zero differences, and its
tests pin the normalization itself. Step two replaces the `:v2` internals with
the new computation; every difference the harness then reports is caused by
step two and must be classified.

### D3. The v2 computation consumes Phase 2 evidence, not labels

`:v2` reads rotations, activities, overrides and approved coverage as today,
but interprets activities through `activity_source_classifications` (resolved,
context-required, recognized-unclassified, unmapped), `activity_source_timings`
and `source_identity_mappings`, never by matching raw labels at read time.
Rules stay as small named, versioned policies in code, one module each, with
the same names as the Phase 2 policy metadata:

- `night_boundary` (Strong canonical night blocks shift to the evening before;
  explicit Friday nights and override-protected dates are preserved);
- `friday_strong_correction` (applied exactly once, from the literal Friday
  activity);
- `saturday_highland_gap` (the named Saturday exception for the HH Nights pair);
- `gap_fill` (dated activity on a day without rotation or coverage, using the
  resolved type or `qgenda_assignment` for anything not resolved);
- `coverage_precedence` (approved overrides win; covering elsewhere removes the
  covering resident's own duty; cross-schedule coverage is visible).

Context-required classifications are resolved here with the day's base
rotation and weekday, which is the context Phase 2 deliberately did not
evaluate. Recognition alone still never establishes a service. Unknown labels
remain visible as unmapped duties with their raw label.

### D4. Differences are classified, never averaged

The harness reports, per schedule, aggregate counts of identical days,
differing days, differing calendar events and differing consumer outputs, and
returns resident-level detail only in memory to an administrator running it on
the host. Every differing day is attributed to one of:

- `regression`: v2 is wrong; fix v2 before proceeding;
- `legacy_defect`: an existing path is wrong (the inconsistencies listed above
  are candidates); fix the legacy path in its own PR first, so the comparison
  returns to zero, or record it below as approved;
- `approved`: an intentional behavior change, recorded in
  `schedule-effective-read-approved-differences.md` with the scenario and the
  user's decision.

Phase 3 is done only when every schedule compares with zero unclassified
differences and every `legacy_defect` is either fixed or approved. Row counts
and totals are never accepted as evidence on their own.

### D5. Where the comparison runs and what leaves the host

- `ResidencySchedule.EffectiveSchedule.Comparison.run(schedule_id)` is a
  context function with a `Release.compare_effective_schedule/1` wrapper, run
  through the `DEPLOY.md` manual-eval command by the deploy user. It prints
  aggregate counts; detail is available only by inspecting the returned term
  in that session.
- No comparison results are stored in the database or written to files.
- Telemetry exports only counts, through a new `schedule_compare` phase and a
  `mismatches` count key in `Observability.Tracing`, following its allowlist
  conventions. No labels, dates or identifiers.
- Repository tests use synthetic fixtures only: the checked-in CSV years, the
  QGenda workbook fixtures, the staging fixtures and the Phase 2 doctest
  fixtures. The scenarios in the release plan's acceptance contract each get a
  named fixture and a test.

### D6. Controls are built last and stay off

Phase 4 needs per-schedule read routing, so Phase 3's final PR adds the
schema and context for it without enabling anything: a `schedule_read_settings`
row per schedule with `projection_version` (`legacy` default, `v2`) and
`compare` (boolean, default false), administrator-only mutation, and the
projection version included in the `ScheduleCache` key. Consumers keep calling
the legacy paths; the only runtime effect of `compare: true` is the aggregate
telemetry from D5 after a cached build. A pause control for mutations is not
part of Phase 3.

### D7. Performance acceptance

The v2 computation for one full schedule must complete within twice the
legacy projection's time on the existing `benchmarks/schedule_cache.exs` data,
measured locally and recorded in the verification record. The comparison
itself has no production latency budget because it never runs on a request.

## Delivery order

Each PR follows the test-writer, runner, reviewer, implementer, independent
review workflow with recorded hashes, plus a verification record.

1. **Service interface and comparison harness (`:v2` = adapter).**
   Normalization, the legacy adapter, the daily and calendar comparison, the
   release wrapper, aggregate telemetry, acceptance-scenario fixtures. Zero
   differences by construction; the tests pin the normalization.
2. **v2 computation.** The named policies from D3 over Phase 2 evidence, with
   the harness as the regression gate. Expected first findings are the listed
   legacy inconsistencies; each is classified per D4. Legacy-defect fixes ship
   as separate small PRs before this one is accepted.
3. **Consumer-output comparisons.** Statistics (shifts remaining, shared
   shifts, matrix cells, duty-hour estimates), coworker and day rows, assistant
   summaries, calendar feeds, computed from both versions and diffed; the
   compare page and `search_activities` are read-only and out of scope.
4. **Read controls, unused.** D6.

## Out of scope

Switching any consumer (Phase 4), the common writer (Phase 5), removing
compatibility columns (Phase 6), exact timings from new adapters, a mutation
pause, and any recovery or backup program. The
[snapshot-and-rebuild decision](schedule-adapter-recovery-decision.md) stands.

## Open questions for the user before PR 2

- Which of the known legacy inconsistencies should be treated as defects to fix
  in the legacy paths, and which as approved differences? The default in this
  plan is: coverage-segment type, cross-schedule gap filling and month-summary
  overrides are defects; the duty-hour overlap rule is approved as an estimate.
- Whether `qgenda_assignment` gap fills for context-required tasks should keep
  their current neutral type in v2 or be resolved with day context. The default
  is to resolve with context, which will show as differences to be approved.
