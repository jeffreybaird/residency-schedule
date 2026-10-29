# Effective-schedule read comparison verification

Recorded October 28, 2026 for Phase 3 of the
[schedule adapter release plan](schedule-adapter-release-plan.md), implementing
[the Phase 3 read plan](schedule-effective-read-plan.md). This records local
isolated test-database work only. No production deployment, migration, backfill
or credentials were accessed. No comparison result was stored or written to a
file; repository tests use synthetic fixtures only.

## PR 1: service interface and comparison harness (`:v2` = adapter)

### Baseline and environment

- Starting source: merged `main` commit
  `4da2901a1c6bb6fa289d025d1974acb67bd758db`, branch `claude/zen-sagan-064vo0`.
- Elixir 1.19.5, Erlang/OTP 28 (`.tool-versions`).
- Lock SHA256:
  `52e797eba31a48eee06a6a235a41c40b5b33e277ee7a4edfc1bed6ade8131136`.
- Baseline `mix test`: 278 doctests, 1866 tests, 1 failure (102.9 seconds);
  the failing test passed on `mix test --failed` and is treated as a
  parallel-isolation flake, named below if it recurs.
- `mix hex.audit`: "No retired or security advisory packages found." This is
  a Hex package advisory check only.

### Accepted contract and red run

The spec writer wrote the tests from the orchestrator's design brief (plan D1,
D2, D5). The reviewer accepted them with three required changes (two Elixir
string-escape errors in expected iCalendar summaries, and registering the
`Ical` doctests). After implementation, Credo reported two alias-order findings
in test files; the alias-only edits were re-accepted by the reviewer with the
assertions unchanged. Process deviation: both correction rounds were applied
by resuming the spec-writer agent, which the audit hook recorded as a
`general-purpose` role, so `.agent-audit/bash.jsonl` lists those five edits as
ambiguous `violations`. The reviewer compared the diffs to the required edits
and the hashes below are the accepted set. The accepted hashes:

| Path | SHA256 |
| --- | --- |
| `test/residency_schedule/effective_schedule/normalize_test.exs` | `d23abafd71841be63c0e0a4e0ccb72820ea2b497ec219da5ca71ff2a400f2db1` |
| `test/residency_schedule/effective_schedule/effective_schedule_test.exs` | `c2e2c483a6bf0be4cfa15e58c94045d09edf372ad4df5c074377769427807e60` |
| `test/residency_schedule/ical_events_test.exs` | `8463ed297898f72612aa9b3203ad0e3217cf9e448eef21f8e5aeb234f58a7e6c` |
| `test/residency_schedule/effective_schedule/comparison_test.exs` | `09d9ea790d1976df79df7e85d5f3142fae7d3ee1ffd40f92d33166f087554465` |
| `test/residency_schedule/release_compare_test.exs` | `d515916c85087621513da878ed3700c1c72bdbd271db84228aa5c1bd26931aad` |
| `test/residency_schedule/observability_test.exs` | `512ca67589fa73c9ed72bcc077578babff08bcffea3a32997e4deaafe303155b` |
| `test/residency_schedule_web/operation_tracing_test.exs` | `5b7fa6a4b81af559be30b480cbc3e5efa5fdb5ee72385005bbcb4515c301b9dc` |

The runner recorded the red run before the two escape corrections (which
change expected values only) with `LC_ALL=C.UTF-8 mix test <file>` per file:

| File | Result |
| --- | --- |
| `normalize_test.exs` | did not compile: `doctest Normalize` on a missing module |
| `effective_schedule_test.exs` | 19 tests, 19 failures, all `UndefinedFunctionError` on `EffectiveSchedule` |
| `ical_events_test.exs` | 10 tests, 10 failures, `Ical.events_from_segments/2` undefined |
| `comparison_test.exs` | did not compile: `doctest Comparison` on a missing module |
| `release_compare_test.exs` | 2 tests, 2 failures, `Release.compare_effective_schedule/1` undefined |
| `observability_test.exs` | 9 tests, 0 failures (see below) |
| `operation_tracing_test.exs` | 14 tests, 2 failures: no `schedule.compare` span; `Comparison.run/1` undefined |

The appended `observability_test.exs` case is green before implementation
because unknown phases and count kinds fall through in `Tracing`; it is kept
as a result-preservation test, and the exported-span assertions in
`operation_tracing_test.exs` are the red evidence for the allowlist.

Normalization decisions pinned by the accepted tests, beyond the plan text:

- The schedule date range is the earliest start to the latest end over all
  effective segments, including gap fills and coverage, so blank days exist
  for every membership across that range.
- Legacy duties always carry `timing: %{precision: :date_only, period: nil}`;
  legacy never yields `:dated_activity` or `:explicit_off`.
- Coverage duties carry the stored rotation type of the covered rotation,
  which is the first plan-listed legacy inconsistency to classify in PR 2.
- Cross-schedule coverage can make `for_schedule` and `calendar_events`
  disagree (the schedule view groups overrides by the covered schedule, the
  person feed reads covers across schedules); deferred to PR 2 classification.
- `diff_events/2` returns the symmetric difference per person in ascending
  person order, legacy-only entries in input order before v2-only entries.

The reviewer's advisory review: `mix hex.audit` reported no retired or
advisory packages; `mix deps.audit` is unavailable (`mix_audit` is not a
dependency), so no CVE/GHSA database scan was possible.

### Implementation and green run

The implementer added `ResidencySchedule.EffectiveSchedule` (with
`Normalize`, `LegacyAdapter` and `Comparison`), `Ical.events_from_segments/2`
(the feed builders now render from structured events, with the feed text
unchanged), `Schedules.get_schedule/1`, the `schedule_compare` phase and
`mismatches` count in `Observability.Tracing`, and
`Release.compare_effective_schedule/1`. Both versions route to the legacy
adapter, so the comparison reports zero differences by construction.

The runner's green record, with all seven accepted hashes matching:

- `mix format --check-formatted`, `mix compile --warnings-as-errors` and
  `mix credo --strict` (3025 mods/funs, no issues): exit zero.
- The seven accepted files: 24 doctests, 89 tests, 0 failures (seed 521994).
- Full `mix test`: **302 doctests, 1935 tests, 0 failures**, 101.4 seconds,
  seed 295894 (a prior full run also passed). The baseline flake did not recur.
- `mix hex.audit`: no retired or advisory packages; `mix deps.audit` is not
  available.

The independent review approved the implementation: the adapter normalizes
`effective_segments_for_schedule/1` faithfully, `build_from_segments/2` output
is byte-for-byte unchanged, nothing resident-level is printed, logged, stored
or exported, and every public function has a doctest or a stated database
exemption. One recorded deviation from plan D1: working days carry `off: nil`,
which the accepted tests pin.

### Acceptance-scenario fixtures

A second, test-only round added `ResidencySchedule.EffectiveScheduleFixtures`
(`test/support/effective_schedule_fixtures.ex`) with one synthetic fixture per
read-side scenario of the release plan's comparison contract, and
`test/residency_schedule/effective_schedule/acceptance_test.exs`, which runs the
comparison on each and pins the current legacy meaning: the April 5–18 vacation
from roster weekdays and imported weekends with dated notes; a clinic activity
on a rotation day (invisible in legacy); gap filling and coverage precedence;
Strong canonical and explicit-Friday night boundaries, the Friday correction,
Highland post-call trimming and the Saturday Highland gap rule; blank, OFF,
unknown and relabeled tasks; identical reimport and a correction. Each
scenario compares with zero differences. Deliberately out of scope here:
ambiguous people, consumer outputs and incomplete QGenda exports.

The reviewer accepted the tests after one moduledoc edit, verifying every
pinned value against the projection, feed and importer code. Accepted hashes:
`test/support/effective_schedule_fixtures.ex`
`63ddcfcddebedd50aef68e83395ee04080436c71e9eb44fa9a8ac1ab6b5aede6`;
`test/residency_schedule/effective_schedule/acceptance_test.exs`
`fed727a37a6f9d0e588c372870a968aa0915c9e64e85512bf7ba23857dcab97a`. The runner's
record: format, compile and Credo clean; the acceptance file 23 tests, 0
failures; full `mix test` **302 doctests, 1958 tests, 0 failures** (seed
79515). Hex audit clean; no CVE-level audit tool is available.

### Legacy findings to classify (plan D4)

- `legacy_defect`: a one-day all-day segment immediately before a night block
  without a source date (for example Saturday post call before Highland night
  float) is emitted as a zero-length all-day event (`DTEND == DTSTART`),
  which calendar clients drop. Fix in its own small PR (skip the trim when it
  would empty the event; the UID does not change), with a spec-writer revision
  of the acceptance assertion that pins the current output.
- `approved` (importer write behavior, outside the read comparison): an
  identical whole-year CSV reimport regenerates every `schedule_residents` id
  while person ids stay stable; whole-year replacement is already refused once
  detail links exist.
- Expected v2 differences, pinned so the harness surfaces them in PR 2: a
  clinic on a rotation day is not a distinct duty; OFF is a working
  `qgenda_assignment` gap fill; coverage duties carry the stored rotation
  type; Sunday Highland night tasks resolve to `qgenda_assignment`.

### Next

PR 2 replaces the `:v2` internals with the Phase 2 policies and classifies
every difference the harness then reports; the open questions in the read
plan need the user's answers before PR 2 starts.
