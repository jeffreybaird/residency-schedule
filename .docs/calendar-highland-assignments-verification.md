# Highland calendar assignments verification — October 12, 2026

Authoritative workflow-runner evidence. The runner did not edit source or tests.
Runtime: Elixir 1.19.5 on local OTP 29.0.1; repository-pinned OTP 28.5.0.7 was not
installed locally. Mix required native escalation for local sockets/test database.

## Red and contract review

All focused commands used `MIX_ENV=test mix test <paths> --seed 0`.

- `test/residency_schedule_web/live/calendar_highland_assignments_test.exs`:
  initial execution failed test compilation because `@type` is reserved. The
  writer renamed that attribute before the behavioral red run; no source changed.
- Corrected Highland contract: exit 2; 4 tests, 2 failures, 0.5 seconds. Missing
  day/modal Highland grouping and month indicator failed; deduplication and
  weekday/unknown exclusion passed. Log: `/tmp/calendar-highland-red.log`.
- `test/residency_schedule_web/live/calendar_redundant_assignments_test.exs`:
  exit 2; 6 tests, 6 failures, 0.5 seconds. The exact Ambulatory R1–R4 and Elective
  R3–R4 labels still repeated their matching headings.
  Log: `/tmp/calendar-redundant-red.log`.
- After initial Highland implementation, its four tests passed, 0.5 seconds.
  Log: `/tmp/calendar-highland-green.log`.
- Reviewer-added base-coverage-summary and excluded-base-fallback regressions:
  both failed against the intermediate implementation. Combined two-file run:
  exit 2; 12 tests, 2 failures, 0.7 seconds; prior ten tests passed.
  Log: `/tmp/calendar-highland-review-red.log`.

Reviewer acceptance preceded each corresponding implementation. The final contract
preserves raw assignments and notes, exact Saturday-only classification, base/task
resident deduplication, calendar indicators/counts/filtering, existing base coverage
summaries, and unclassified task visibility when the base rotation is excluded.
Redundant task text is suppressed only under its matching rotation heading.

Final accepted SHA-256 hashes:

```text
86a1f7def20f37d91b4a1a14f918621c09414f99f83d5af10f9434e867c30688  test/residency_schedule_web/live/calendar_highland_assignments_test.exs
ee8d7fc58dd24ec2c4e7716567f1c8edafbaa21bec155eea7d7a6888dfa20ea3  test/residency_schedule_web/live/calendar_redundant_assignments_test.exs
```

## Green verification

Owners formatted source/tests before read-only runner checks.

Focused command:

```sh
MIX_ENV=test mix test test/residency_schedule_web/live/calendar_highland_assignments_test.exs test/residency_schedule_web/live/calendar_redundant_assignments_test.exs test/residency_schedule_web/live/calendar_rotation_groups_test.exs test/residency_schedule_web/live/daily_assignment_integration_test.exs test/residency_schedule_web/live/calendar_live_test.exs --seed 0
```

- Focused regressions: exit 0; **1 doctest, 72 tests, 0 failures**, 7.7 seconds.
  Log: `/tmp/calendar-highland-focused-green.log`.
- `MIX_ENV=test mix format --check-formatted`: exit 0.
- `MIX_ENV=test mix compile --warnings-as-errors`: exit 0.
- `MIX_ENV=test mix deps.unlock --check-unused`: exit 0.
- `MIX_ENV=test mix credo --strict`: exit 0; 272 files, 2,217 modules/functions,
  no issues. Log: `/tmp/calendar-highland-checks.log`.
- `MIX_ENV=test mix test --seed 298741`: exit 0; **196 doctests, 1,458 tests,
  0 failures**, 46.6 seconds. Log: `/tmp/calendar-highland-full-green.log`.
  The private-data sentinel in its output is intentional test output.
- Accepted test hashes above remained unchanged after final execution.
- `git diff --check`: exit 0.

## Security scope

Dependency versions are unchanged since the same-session
[security review](qgenda-oct12-security-review.md). Its current advisory results and
known host OTP findings remain applicable. No clean-host or production-runtime
claim follows from functional verification; the runner did not modify production.

## PR 55 approved expansion of repeated-label suppression

The user reviewed and approved the proposed mapping, including the SMH labels,
before implementation. The exact 34-label map suppresses a task only under one of
its approved matching headings. Raw tasks and notes remain intact; unknown labels,
wrong-heading cases, clinic details and HH night duties remain visible.

The initial broader plain-label contract had 28 tests and 15 expected failures
(exit 2, seed 0, 2.1 seconds; `/tmp/calendar-redundant-expanded-red.log`). Work paused
for user review. After explicit approval, the writer revised the SMH expectations
and two existing calendar assertions, and the reviewer accepted the new contract.

Authoritative approved-contract red command:

```sh
MIX_ENV=test mix test test/residency_schedule_web/live/calendar_redundant_assignments_test.exs test/residency_schedule_web/live/calendar_rotation_groups_test.exs test/residency_schedule_web/live/daily_assignment_integration_test.exs --seed 0
```

Exit 2: **1 doctest, 77 tests, 43 expected failures**, 3.8 seconds.
Log: `/tmp/calendar-redundant-approved-red.log`.

Current accepted hashes, superseding previous hashes only for these revised files:

```text
27b38d61cfa711ba1a84129c1c334ee1a919a9bb3be55ad6d229047b02148255  test/residency_schedule_web/live/calendar_redundant_assignments_test.exs
f8a0f95188190c6f8fdc63c765cce5ed73c9232bbd597956f72dc1a7f62b5ea3  test/residency_schedule_web/live/calendar_rotation_groups_test.exs
49352f1a3c564385b3f085d1272aa4431bfc6c12aebc4511b0d04915d79cb4e9  test/residency_schedule_web/live/daily_assignment_integration_test.exs
```

After source-owner formatting:

- Focused green: the three files above plus `calendar_highland_assignments_test.exs`
  and `calendar_live_test.exs`, `MIX_ENV=test mix test ... --seed 0`: exit 0;
  **1 doctest, 124 tests, 0 failures**, 11.6 seconds.
  Log: `/tmp/calendar-redundant-approved-green.log`.
- `MIX_ENV=test mix format --check-formatted`: exit 0.
- `MIX_ENV=test mix compile --warnings-as-errors`: exit 0.
- `MIX_ENV=test mix deps.unlock --check-unused`: exit 0.
- `MIX_ENV=test mix credo --strict`: exit 0; 272 files, 2,215 modules/functions,
  no issues. Log: `/tmp/calendar-redundant-approved-checks.log`.
- `MIX_ENV=test mix test --seed 298741`: exit 0; **196 doctests, 1,510 tests,
  0 failures**, 52.8 seconds. Log: `/tmp/calendar-redundant-approved-full.log`.
- All three accepted test hashes remained unchanged after final execution.
- `git diff --check`: exit 0.

Dependency versions remain unchanged; the same-session security evidence and
runtime limitations above still apply.
