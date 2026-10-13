# Schedule cache verification

## Contract and red evidence

The spec writer defined 17 tests across cache coordination, ordinary-pool
integration, and SQL Sandbox isolation before implementation. Independent review
accepted the behavior contract. The runner initially recorded expected missing
API failures, but a fixture-cleanup defect caused subsequent integration setup
failures; those setup errors were not treated as behavioral red evidence.

The writer corrected raw SQL calls to target `Repo.get_dynamic_repo()` instead
of the default sandbox repository. The reviewer accepted that isolation-only
correction. The runner then recorded **17 tests, 17 expected failures**, with
no fixture setup failures, in `/tmp/schedule-cache-red-cleanup-fixed.log`.
The runner verified that no synthetic 2095/2096 schedules remained afterward.

Final accepted SHA-256 hashes (including reviewed doctest registration, sandbox
setup, warning corrections, and alias-only formatting corrections):

| Test | SHA-256 |
| --- | --- |
| `test/residency_schedule/schedule_cache_test.exs` | `bd5bcfc8668209da2ca3338301ddae8bf6f52c949b9cedbbb5c66c02e01dc220` |
| `test/residency_schedule/schedule_cache_integration_test.exs` | `c524cc021f614f4bc06d5d203517b2dc711c4330f8053a888816272c414302b2` |
| `test/residency_schedule/schedule_cache_sandbox_test.exs` | `1f8b82db333181365a04dc3e624f1ef192486b44e0cee21a2a946a0b1ebff47e` |
| `test/support/data_case.ex` | `2362778bb2ca6fd14c9a61864ea0bf5ba44755d5373e39277b0d04e254efc6ef` |
| `test/residency_schedule/contexts/schedule_fixture_isolation_test.exs` | `9aad37e8752eff4f12bbf5e6d839f7c9a6f4d60721cbb39edede14704ebbc677` |
| `test/support/benchmarks/schedule_cache.exs` | `d85c33248358c5359b430d19d13eb114eacd1c5d11aa5b7598ca1986ee1d7b11` |

The tests cover single-builder coordination, capacity, owner failure, revision
visibility and rollback, all seven source tables, stale publication, date and
dynamic-repository keys, bounded revision retries, real admin edit and override
success/failure, mutation lock ordering, and warm static/connected mounts.

## Baseline performance

The reproducible benchmark is `test/support/benchmarks/schedule_cache.exs`. The runner
captured the pre-cache baseline in an isolated migrated database with an ordinary
connection pool, then dropped that database. This avoids measuring the deliberate
SQL Sandbox bypass as a cache hit. Baseline evidence:
`/tmp/schedule-cache-baseline-connection-pool.log`.

The synthetic fixture contains four years, 128 schedule-resident records,
10,404 rotations, and 11,680 detailed activities. Output is 56 unified rows,
611 slots, 13,437 grouped cells, and 10,275,827 HTML bytes. All five runs returned
identical grid data and HTML. Mount times were 642.8, 629.1, 1,206.0, 625.3, and
1,331.4 milliseconds, with 27 queries each. The host timings vary substantially;
query counts and repeated-build elimination complement wall-time measurements.

## Cache performance and migration

The first cache run measured a cold mount at 681 milliseconds and 32 queries,
then warm mounts at 24.9–57.4 milliseconds and one revision query each. The final
benchmark additionally constructs an uncached reference using the same dataset
and asserts exact grid and HTML equality for every cold and warm result. That
run measured a cold mount at 999.6 milliseconds and warm mounts at 26.6–80.6
milliseconds, again 32 cold queries and one warm query. Evidence:
`/tmp/schedule-cache-after-verified.log`.

The cache removes repeated preparation work; it does not shrink the 10.3 MB HTML
output or eliminate rendering. Cold builds use serial transaction preloads for
snapshot consistency. No claim of a cold-build optimization is made by this PR.

The runner rolled migration `20261013143545` down and up in the disposable
benchmark database, verified all seven triggers returned, and confirmed all
10,404 fixture rotations survived. Evidence:
`/tmp/schedule-cache-migration-smoke.log`. The database was dropped afterward.

## Verification

The full suite passed: **211 doctests, 1,592 tests, zero failures**, seed
`238741`, `/tmp/schedule-cache-green-full.log`. Browser latency tests passed
all ten cases. Compile, read-only formatting, and unused-dependency checks passed.
Strict Credo initially requested alias ordering and equivalent catch syntax
corrections; the responsible source/test owners applied them and force-formatted
their files. Independent review verified unchanged test assertions.

The initial focused run encountered a local migration tracking entry created
when a red test run saw the empty generated migration scaffold. The runner
verified the revision table, function, and triggers were absent, removed only
that exact local test migration record, and reapplied the completed migration.
This was a development-test setup correction, not an application migration or
data reset. The repaired focused run passed all 17 cache tests.

Final focused verification passed **2 doctests and 18 tests**. After the last
alias-only correction, the integration file passed all ten tests again
(`/tmp/schedule-cache-green-integration-accepted.log`). Strict Credo passed
287 files and 2,357 modules/functions with no issues
(`/tmp/schedule-cache-green-credo-accepted.log`). Final formatting and compilation
with warnings treated as errors also passed. Independent final review approved
the source, migration, accepted test hashes, privacy boundaries, and audit log;
no required verification remains outstanding.

Fresh dependency and runtime advisory evidence is in
[schedule-cache-security-review.md](schedule-cache-security-review.md).
