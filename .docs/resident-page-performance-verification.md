# Resident page performance verification

## Diagnosis before implementation

Branch baseline: `3e5dd4b`. Measurements use a disposable local database, `residency_schedule_cache_bench_resident`, seeded with four synthetic academic years, 10,404 rotations and 11,680 detailed activities. The representative resident appears in all four years and has 817 career entries and 21 coworkers. No production or development database was read or profiled.

Instrumentation aggregates repository telemetry into public ETS counters, including queries executed by parallel preload processes. Function call counters establish repeated projection work. Render measurements invoke actual Phoenix `Renderer.to_rendered/2` and `Diff.render/4`, retain fingerprints between updates and clear changed assigns; JSON encoding is timed separately.

| Operation | Observed baseline |
|---|---|
| Mount, three runs | 1,379.296 / 1,279.573 / 1,191.075 ms |
| Mount queries | 106 each run |
| Summed database time | 522.7–565.8 ms |
| Mount process reductions | 183.7–184.1 million |
| Complete-schedule projections per mount | 10 |
| Resident projection calls per mount | 9 |
| Effective-resident rebuilds per mount | 4 |
| Initial connected render | 4.0–21.3 ms; approximately 0.9–1.0 million reductions |
| Initial uncompressed diff | 492,348 bytes |
| Initial JSON encoding | 4.8–6.5 ms |
| Current-year projection in isolation | 286.9 ms, 9 queries |
| Current-year effective segments | 257.6 ms, 11 queries; repeats the projection |
| Eager coworker computation | 308.7 ms, 14 queries |

The mount builds full schedules and then filters to one resident. It projects the selected year once, each career year twice, and the selected schedule again for coworkers. `DetailedSchedules.list_for_schedule/1` runs ten times per mount. This repeated loading and projection dominates the synthetic request; connected rendering is substantially smaller.

## Local profile

An explicit eprof session traced only the benchmark's current process and was stopped afterward. Function aggregates contain no argument values or schedule content. Profiling itself changes execution cost; its approximately 7.15 seconds of recorded function time is not the normal mount latency.

The repeated gap projection predicate ran 2,186,056 times. `Date.range` ran approximately 2.21 million times and `Date.to_iso_days` approximately 6.65 million times. `Calendar.ISO.date_to_iso_days/3` accounted for 16.67% of exclusive recorded time, with related date-validation/conversion helpers accounting for substantial additional work. Detailed activity presentation ran 47,086 times, reflecting repeated loading of the current year's detailed schedule.

These results support first reusing projections within one mount and loading coworkers only when requested. They do not establish production's precise CPU/database split. They do not justify changing date semantics or virtualizing the resident timeline without separate evidence.

## Subsequent interactions

- Switching to the already-loaded coworkers tab: approximately 0.03 ms render and 4.6 KB diff.
- Returning to the Schedule tab: approximately 4 ms render and 488 KB diff.
- Opening one shift's coworker modal: 26–43 ms handler time with eight queries; approximately 0.05 ms render and 4 KB diff.

## Evidence and privacy

- Raw local evidence: `/tmp/resident-performance-baseline.log`.
- Reproduction artifact: `/tmp/resident-performance-baseline.exs`.
- The disposable database was retained for the same-row after comparison and then dropped after final browser verification.
- Any added application tracing must use fixed operation labels and bounded aggregate counts. Resident identifiers, names, URLs, SQL, activity text and payloads must not be exported.

## Accepted scope

Stage one reuses mount projections, defers coworkers and adds bounded resident tracing. No vertical windowing is included. Stage-one focused verification and measurements follow below. Stage-two measurements and final automated verification follow below.

## Stage-one red contract

`MIX_ENV=test mix test test/residency_schedule/resident_schedule_data_test.exs test/residency_schedule_web/live/resident_performance_test.exs test/residency_schedule_web/operation_tracing_test.exs test/residency_schedule/observability_test.exs --seed 0` returned exit 2: 25 tests, seven expected failures and 18 passes. Missing context data APIs, lazy coworker state, resident trace phases and resident metric classification account for the failures. Evidence: `/tmp/resident-performance-red.log`.

The writer corrected the legacy whole-map oracle to include its existing `specific_tasks: []` and `specific_notes: []` keys. The reviewer accepted this correction. Rerunning the three performance tests produced three intended lazy-state failures (`/tmp/resident-performance-red-oracle.log`).

Accepted hashes before implementation:

```text
968a47961bfa82251094f93189d2af7f6680e698c256a1dc0220cd99830db2b5  test/residency_schedule/resident_schedule_data_test.exs
fb1a56149527edab3fc225c082fc1ba980f06b374265298b627e9b3cd654e34e  test/residency_schedule_web/live/resident_performance_test.exs
d3d79bfd04e2fb016f49dd90c932215110ae054c82f5afaad85f2d0fb2358fa7  test/residency_schedule_web/operation_tracing_test.exs
68f95b932aecf60b0c6e1eed4e1356285bc8aff70105e8b1367f741c3ed9938e  test/residency_schedule/observability_test.exs
604ac6078b2f5a2af5f06200ad7eca6f880df646f10f738c98e47bd09e883fea  test/support/resident_performance_fixtures.ex
```

## Stage-one measurement

The authoritative focused run passed **25 tests** (`/tmp/resident-performance-green-focused.log`). The same synthetic database rows were then measured again:

- Mount: **479.592 / 408.086 / 437.692 ms**, **32 queries** each, approximately **48.7 million reductions**.
- Detailed schedule loading: four calls, one per appearance, compared with ten before. No eager coworker computation occurs during mount.
- Career content remains 817 entries. Initial connected diff remains exactly **492,348 bytes**.
- First opening of Coworkers: **301.8–311.8 ms**, 15 queries. The work is now deferred until requested; it is not eliminated.
- The remaining gap-coverage predicate executes **546,514** times, compared with 2,186,056 before. Local profiling still attributes substantial work to repeatedly constructing date ranges and converting dates.

Evidence: `/tmp/resident-performance-after.log`, artifact `/tmp/resident-performance-after.exs`. The user-authorized second stage will optimize this measured membership work with exact-equivalence and deterministic scaling tests; no additional cache is planned. The completed second-stage measurements and verification follow below.

## Stage-two red contract

`MIX_ENV=test mix test test/residency_schedule/schedule_gaps_index_test.exs --seed 0` returned exit 2: **five tests, one expected scaling failure**. Four exact-equivalence tests passed. Doubling disjoint point rotations and alternating uncovered activities from 512 to 1,024 increased process reductions from **17,490,911 to 69,821,460** (3.99×), exceeding the accepted 3× ceiling. Evidence: `/tmp/resident-gaps-index-red.log`.

The reviewer accepted these hashes before implementation:

```text
982e821d6ecfac0405329a4687e8b43a4414758d77bf3c8651806e65ea89bd7e  test/residency_schedule/schedule_gaps_index_test.exs
3babf05767e6944efdeec153dbbe4a386353668b3865c5bd094a350309938c89  test/support/schedule_gaps_reference.ex
```

The frozen reference preserves baseline behavior, including reversed date ranges. Its expected runtime warnings make the local red log large; they are unrelated to the scaling failure.

## Final same-row measurement

The interval index uses merged coverage intervals and binary-search membership. It avoids expanding long intervals or repeatedly constructing date ranges. The same retained synthetic rows produced:

| Measure | Baseline | Final |
|---|---|---|
| Mount wall time, three runs | 1,379.296 / 1,279.573 / 1,191.075 ms | 421.028 / 268.067 / 268.827 ms |
| Mount repository queries | 106 | 32 |
| Mount process reductions | 183.7–184.1 million | 12.9–13.1 million |
| Detailed schedule loads per mount | 10 | 4 |
| Career entries | 817 | 817 |
| Initial uncompressed diff | 492,348 bytes | 492,348 bytes |
| Initial connected render | 4.0–21.3 ms | 3.8–24.7 ms |
| First Coworkers handler | Eager during mount | 203.9–221.1 ms; 15 queries |
| Return to Schedule handler | Negligible | 0.002–0.005 ms; no queries |

Host, database and scheduling noise affect wall times. Query counts, reductions, exact content contracts and encoded size give stronger comparisons than these three timings alone. The initial resident timeline still renders in full; this change does not reduce its approximately 492 KB payload.

The remaining warm mount's summed database time was 134.8–139.1 ms, mostly query time. These aggregate query durations can overlap during parallel preloads and are not a strict elapsed-time partition. Isolated older-year full projections took 12.6–13.6 ms each. The current-year full projection took 248.3 ms with nine queries and 145.1 ms summed database time in its separate sample. It still loads detailed activities for the whole schedule before selecting this resident.

The final process-only eprof run shows remaining work spread among Ecto struct/type loading, collection transforms and date conversion. `ScheduleGaps.occupied_day?/4` now accounts for 0.32% exclusive sampled function time (46,872 calls), replacing the prior 546,514 repeated range predicates after stage one. Ecto adapter loading and struct loading account for 3.23% and 3.17%; a general Enum map helper accounts for 4.20%. Profiling overhead and exclusive function attribution prevent interpreting these percentages as production request timing.

Evidence: `/tmp/resident-performance-final.log`. Reproduction on the retained disposable fixture: `SCHEDULE_BENCHMARK_DATABASE=residency_schedule_cache_bench_resident RESIDENT_EPROF=true MIX_ENV=test mix run --no-start /tmp/resident-performance-after.exs`. The earlier baseline artifact creates the fixture; the after artifact only reads it. Profiling stops in an `after` cleanup block. No production profiler or new cache was added.

## Final automated verification

All commands completed successfully after source-owner formatting:

- Focused: `MIX_ENV=test mix test test/residency_schedule/schedule_gaps_index_test.exs test/residency_schedule/resident_schedule_data_test.exs test/residency_schedule_web/live/resident_performance_test.exs test/residency_schedule_web/operation_tracing_test.exs test/residency_schedule/observability_test.exs --seed 0`: **30 tests, zero failures**.
- Full suite: `MIX_ENV=test mix test --seed 238741`: **214 doctests, 1,648 tests, zero failures**.
- Browser assets: `node --test test/assets/*.test.js`: **38 tests, zero failures**.
- `MIX_ENV=test mix compile --warnings-as-errors`: passed.
- `MIX_ENV=test mix format --check-formatted`: passed; the runner performed no formatting edits.
- `MIX_ENV=test mix deps.unlock --check-unused`: passed.
- `MIX_ENV=test mix credo --strict`: **306 files, 2,509 modules/functions, no issues**.
- SHA256 verification: all seven accepted test and fixture hashes above remain unchanged.

Logs: `/tmp/resident-performance-final-focused.log`, `/tmp/resident-performance-full.log`, `/tmp/resident-performance-node.log`, `/tmp/resident-performance-compile.log`, `/tmp/resident-performance-format.log`, `/tmp/resident-performance-deps.log`, `/tmp/resident-performance-credo.log`. Security findings and advisory freshness are recorded separately in `resident-page-performance-security-review.md`.

## Final browser verification and cleanup

The root reviewer tested the final source against the isolated synthetic server in actual Chromium at **1280×900** and **390×900**. Both desktop and mobile checks passed:

- 821 table rows represent all 817 entries and four academic-year headers.
- Coworkers shows 21 results; switching tabs and returning preserves the complete table.
- Shift detail opens and Escape closes it.
- The Ambulatory service filter narrows the table to 28 rows; All restores 821.
- No browser page errors occurred.

Screenshots: `/tmp/resident-performance-1280.png` and `/tmp/resident-performance-390.png`. An earlier browser harness timing/position failure was resolved in verification; it did not require an application change.

The isolated localhost server was stopped. `dropdb -h localhost -U postgres residency_schedule_cache_bench_resident` removed only the task's synthetic database. A query of `pg_database` confirmed zero databases with that exact name. No production or ordinary development data was modified.
