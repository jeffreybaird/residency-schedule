# Parallel schedule-fixture isolation verification

Authoritative runner evidence, 2026-10-03. The runner made no source or test
edits. No production or development database writes occurred. Tests and
diagnostic transactions used test databases only.

## Investigation before correction

The earlier serial-only green did not establish that the observed PostgreSQL
deadlock was unrelated to the feature. This investigation tested that claim.

- Current branch `5ce5517`: `MIX_ENV=test mix test --seed 861585`, ordinary
  parallelism (`max_cases: 16`), passed once: 185 doctests, 1,379 tests.
- Pre-feature base `be6b28d`: an isolated `git archive` checkout in
  `/tmp/residency-deadlock-base`, separate build output and
  `MIX_TEST_PARTITION=_deadlock_base`, ran the same normal parallel seed and
  passed once: 174 doctests, 1,311 tests.

These successful single runs did not rule out a timing-dependent race.
Read-only inspection found two independent asynchronous sandbox transactions
acquiring the same unique academic-year keys in opposite order:

| Test fixture | First inserted year | Second inserted year |
| --- | ---: | ---: |
| `SchedulesTest`: returns schedules ordered oldest first | 2026 | 2023 |
| `ResidentsTest`: setup, then residents-with-shifts filter test | 2023 | 2026 |

An inline diagnostic then called the actual `Schedules.upsert_schedule/2`
API on two independent database connections, with a barrier after the first
insert and bounded waits before the second. Both transactions were rolled back.
This reproduced PostgreSQL **40P01 / deadlock_detected** on **both base and
current code**. Fresh checkouts afterward confirmed zero residual schedule rows
for those years.

The current-code PostgreSQL error identified `schedules` while inserting an
index tuple. Its lock cycle was:

```text
Process 90418 waits for ShareLock on transaction 271941; blocked by process 90421.
Process 90421 waits for ShareLock on transaction 271940; blocked by process 90418.
```

One transaction failed with 40P01; the other completed and rolled back. This
provides runtime evidence that the fixture-key inversion existed at the base,
rather than inferring that from the location of a later failure.

## Permanent regression and fixture correction

The reviewer accepted an independent-connection regression and the fixture-only
change. The regression asserts distinct PostgreSQL backend IDs, coordinates
both first inserts with a message barrier, and bounds all waits. It does not
borrow a shared connection or disable asynchronous execution.

Before correction:

`MIX_ENV=test mix test test/residency_schedule/contexts/schedule_fixture_isolation_test.exs`

exited 2: **1 test, 1 failure**, seed 349836. The expected `:ok` result was
`{:error, :deadlock_detected}`.

The test writer changed the reverse-insertion ordering fixture to use unique
integer academic-year keys outside the fixed calendar-fixture range. The actual
ordering test still inserts newer before older and asserts oldest-first output.
The new regression uses that same helper, so restoring the old shared keys
recreates its deterministic failure. Application locking behavior was unchanged.

Focused green: the isolation regression and schedule context suite passed with
**1 doctest, 19 tests, 0 failures**.

## Final normal parallel verification

The following three seeds were selected before their runs. Each command ran
once, sequentially against the same test database, with normal parallelism and
without `--max-cases 1`, disabled async tests, skips, or retry-until-green logic.

| Command | Result | Duration |
| --- | --- | ---: |
| `MIX_ENV=test mix test --seed 861585` | 186 doctests, 1,380 tests, 0 failures; exit 0 | 43.0 s |
| `MIX_ENV=test mix test --seed 39805` | 186 doctests, 1,380 tests, 0 failures; exit 0 | 30.7 s |
| `MIX_ENV=test mix test --seed 11876` | 186 doctests, 1,380 tests, 0 failures; exit 0 | 30.7 s |

Read-only checks also passed:

- `MIX_ENV=test mix format --check-formatted`: exit 0.
- `MIX_ENV=test mix compile --warnings-as-errors`: exit 0.
- `MIX_ENV=test mix deps.unlock --check-unused`: exit 0.
- `MIX_ENV=test mix credo --strict`: exit 0; 250 files, 2,070 modules/functions,
  no issues.

## Accepted final SHA-256 hashes

```text
6b91ae36712b32d5c268c80eb3df98f40a3132c761d31b860bb9e1b3780100b5  test/residency_schedule/contexts/schedule_fixture_isolation_test.exs
09e271aa4d518a31fb85fd75cadc3f343df02acbb7dd72b4812b13a24a9180b4  test/residency_schedule/contexts/schedules_test.exs
4220b1b795b1d572814689e70d27c5fae5ee96a255be57a645e1a15da5648eed  test/support/schedule_ordering_fixture.ex
```

The regression gained only required helper-doctest wiring after its initial red;
the independent-connection behavioral assertions remained unchanged. See the
[security review](qgenda-security-review.md) for dependency and runtime findings;
passing tests do not establish a clean runtime or production deployment.
