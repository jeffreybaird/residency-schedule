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
