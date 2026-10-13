# Schedule cell index verification

## Accepted contract and red

The spec writer preserved the original cell algorithm in an independent test
reference. Tests compare complete output maps, including grouped-cell identities
and detail tokens, across targeted cases and 40 deterministically generated
fixtures. Cases cover inclusive slot-start coverage, stable equal-type ordering,
overlap, gaps, schedule boundaries, invalid reversed intervals, duplicate and
out-of-order slots, and legacy lookup behavior.

The deterministic performance test measures current-process reductions after
warmup. Doubling nonoverlapping rotations and slots from 512 to 1,024 must use
less than three times the reductions. It does not assert wall-clock latency.
Before source edits, the runner recorded **7 tests, one expected failure**:
reductions grew from **1,641,964 to 6,438,383 (3.92×)**. All six output-equivalence
tests passed. Evidence: `/tmp/schedule-cell-index-red.log`.

Independent review accepted these SHA-256 hashes before implementation:

| File | SHA-256 |
| --- | --- |
| `test/residency_schedule_web/live/schedule_cell_index_test.exs` | `773b8befea2ad22f00cf9f6250e2df8e8550cff42e9de879b5a2448a0ffd48db` |
| `test/support/schedule_cell_reference.ex` | `6cc4f8ba3c6439de4e6830874fbee4cfca9335a06e9cdd5f91c22fdf253d2ff1` |
| `test/support/benchmarks/schedule_cache.exs` | `a4ec70a7a6be6adca050d09a22c5a8d8a64a03903885c2e807dce6a7deb32872` |

## Cold-cell baseline

The runner measured cell computation directly from preloaded rotation lookups,
without cache lookup, database loading, or rendering in the timed section. The
synthetic four-year dataset has 10,404 rotations, 11,680 activities, 56 resident
rows, and 611 slots. Five runs took **301.3–388.6 ms** and **14.93–15.25 million
process reductions**, with exact reference outputs. Evidence:
`/tmp/schedule-cell-index-baseline.log`. The disposable database was dropped.

The reproducible benchmark remains
`test/support/benchmarks/schedule_cache.exs`, extended to compare direct cold-cell
computation against the frozen reference. Cache timing is reported separately.

## Final performance and verification

The final same-fixture comparison ran each algorithm five times directly over
all 56 resident rows. The frozen reference median was **349.122 ms and
15,126,687 reductions**; the indexed implementation median was **109.299 ms and
5,638,001 reductions**. This is approximately 69% less elapsed time and 63% fewer
reductions in this run. Timing varies with VM/GC activity: reference runs ranged
98.6–364.8 ms and indexed runs 86.7–113.8 ms. Reduction counts and exact-output
checks provide complementary evidence beyond noisy timings.

Every result exactly matched the frozen reference, including all 13,437 grouped
cells. The separate whole-grid comparison also confirmed identical cached and
uncached grid maps and HTML. Evidence:
`/tmp/schedule-cell-index-benchmark.log`. The disposable database was removed.

The runner verified all accepted hashes unchanged and recorded:

- Full suite: **211 doctests, 1,599 tests, zero failures**, seed `238741`,
  `/tmp/schedule-cell-index-green-full.log`.
- Focused algorithm and existing ScheduleLive tests: **40 tests, zero failures**,
  `/tmp/schedule-cell-index-green-focused.log`.
- Browser latency tests: **10 tests passed**.
- Compilation with warnings treated as errors, read-only formatting, unused
  dependencies, and strict Credo all passed. Credo checked 289 files and 2,384
  modules/functions without issues.

Static-check evidence uses `/tmp/schedule-cell-index-green-` followed by
`compile.log`, `format.log`, `deps.log`, `credo.log`, or `browser.log`.
Independent final review approved the source and tests, confirming unchanged
grouping, annotation, stable tie ordering, legacy behavior, privacy boundaries,
and cell-token semantics. Audit additions contain no role violations.

Fresh advisory evidence is in
[schedule-cell-index-security-review.md](schedule-cell-index-security-review.md).
