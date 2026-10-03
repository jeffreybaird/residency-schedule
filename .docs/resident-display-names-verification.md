# Imported resident display names: verification

Authoritative runner evidence, 2026-10-03. No source or test files were edited
by the runner. Existing unrelated workflow-document changes were preserved.

## Red and accepted tests

- `MIX_ENV=test mix test test/residency_schedule/contexts/resident_display_names_test.exs test/residency_schedule_web/live/imported_resident_names_test.exs`
  exited 2: **9 tests, 9 failures**, seed 162642. The shared display-name context
  and updated display behavior were absent.
- `MIX_ENV=test mix test test/residency_schedule_web/live/preferred_activity_names_test.exs`
  exited 2: **1 doctest, 4 tests, 1 failure**. The case-only imported-name
  regression failed before its correction; cross-year and nil-input checks
  already passed.
- The reviewer accepted the behavior contracts before implementation. A later
  alias-order correction was test-writer-owned and independently accepted,
  without changing assertions.

## Final green

- Exact final source: `MIX_ENV=test mix test --seed 861585 --max-cases 1`
  exited 0: **175 doctests, 1,356 tests, 0 failures**, 24.1 seconds.
- Final targeted display-name and daily-detail checks: **1 doctest, 21 tests,
  0 failures**.
- A final reviewer-requested capitalization regression was added without any
  source change: `MIX_ENV=test mix test test/residency_schedule/contexts/activity_name_capitalization_test.exs`
  exited 0, **1 test, 0 failures**, seed 26340. It verifies the already accepted
  behavior while preserving original uppercase source text; no retrospective
  red is claimed. The full-suite count above predates this additional test.
- `MIX_ENV=test mix format --check-formatted`: exit 0.
- `MIX_ENV=test mix compile --warnings-as-errors`: exit 0.
- `MIX_ENV=test mix deps.unlock --check-unused`: exit 0, no lockfile edits.
- `MIX_ENV=test mix credo --strict`: exit 0; 243 files, 2,034 modules/functions,
  no issues.

The immediately preceding parallel full run on the final source exited 2 with
one PostgreSQL `40P01 deadlock_detected` in the existing
`SchedulesTest` test “list_schedules/0 returns schedules ordered oldest first.”
It occurred during `Schedules.upsert_schedule(2023, ...)`. Rerunning the same
seed serially produced the final green above. This records the observed
concurrency flake; no test was weakened or skipped to obtain green.

## Accepted final SHA-256 hashes

```text
a8b05080a6ed240be1791f16edce038778a35b26547be8dcdc9a1627feac6b55  test/residency_schedule/contexts/resident_display_names_test.exs
912ec210d9eae34b8ad6a2418a61d92e73505b166eec493c9fb33c2c32598c85  test/residency_schedule_web/live/imported_resident_names_test.exs
1196c36af45e28206c5602b49ab76272f7e48d640d0a8a9a6ae70ee08ea63b7b  test/residency_schedule_web/live/preferred_activity_names_test.exs
db545633cabe816bcd42e129259a00c04934ea33227b7da2067b53019de8e030  test/residency_schedule/contexts/activity_name_capitalization_test.exs
```

See [the dependency and runtime security review](qgenda-security-review.md) for
advisory findings and limitations. Functional green is not a clean-runtime
security claim. No production writes or deployment were performed by the runner.
