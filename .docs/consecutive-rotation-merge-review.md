# Consecutive resident rotation merge review — October 15, 2026

## Accepted test contract

Independent reviewer accepted `test/residency_schedule_web/live/resident_adjacent_rotations_test.exs`, SHA256 `ca0f193a1cbbcbad4040666e58ec74bfd2457d7ed9df345f2b8adf55d6d6fb0a`, before source implementation. The ten behavior tests cover inclusive consecutive chains, task-specific labels, dated notes, full coworker ranges, concurrent independent rotations, preservation of overlapping spans, gaps, unknown imported assignment labels, unmatched daily activities, academic schedule boundaries, and coverage changes. Database rows remain unchanged by presentation merging.

The runner's authoritative refreshed red evidence reports ten tests, four expected merge assertion failures, exit 2, seed 680309; no fixture/runtime errors. Evidence: `/tmp/rotation-merge-red-final.log`. The distinct imported-label regression passes before implementation; the unmatched daily-assignment test initially fails at the missing base merge assertion.

The source approach was reviewed before implementation: operate only on effective task-specific rotation spans within each schedule appearance; group by complete rotation/task/coverage identity; merge only exact next-day spans within each identity; preserve dated notes, first source slot and full date range; retain chronological ordering. Grouping by identity prevents an unrelated overlapping service from interrupting a valid chain. Overlapping spans themselves remain distinct. OFF rows and daily activity rows are excluded from this operation.

## Security

See [current advisory review](consecutive-rotation-merge-security-review.md). The fresh package audit flags pre-existing Bandit 1.12.5, **CVE-2026-105659 / GHSA-69m6-wcv4-rwcf**, with no published patched release in current Hex metadata. This remains an explicit security limitation, independent of functional test results.

## Final implementation review

Independently reviewed the source diff in `lib/residency_schedule_web/live/resident_live/show.ex`: only the intended pipeline call and private span-merging helpers were added. The implementation matches the accepted approach, preserves task labels and dated notes, retains coverage identities, and extends coworker click ranges with the merged dates. No schema, import, stored rotation, calendar, or statistics behavior was changed. No actionable implementation defect was established in the requested scope.

The accepted test hash remains `ca0f193a1cbbcbad4040666e58ec74bfd2457d7ed9df345f2b8adf55d6d6fb0a` after implementation and formatting. The focused runner result is ten doctests and 75 tests, zero failures. The full-suite log reports 216 doctests and 1,696 tests, zero failures; authoritative runner commands and exit status are recorded in [verification](consecutive-rotation-merge-verification.md). Formatting, warnings-as-errors compilation, unused dependency checking, Credo, and `git diff --check` pass. No browser visual inspection was performed.

The audit log remains at its historical baseline of 282 entries and 99 ambiguous violation flags, with no new entries and no exclusive flags. Role communications and final diff/hash inspection support ownership of the task's source and test changes; cloud audit hook activation remains unverified. No unowned source/test edit was established.

**Functional implementation accepted. Security audit and commit gate remain blocked.** The repeated fresh dependency audit exits 1 for the disclosed pre-existing Bandit advisory, with no published patched version available. This review does not approve a commit, mark every required check green, suppress the advisory, or claim completed security remediation. The focused changes remain uncommitted pending resolution of that gate.

## Authorized follow-up — October 15, 2026

The user subsequently authorized disabling application HTTP/2 and a temporary exception with a patch check before every commit. Independent [mitigation review](bandit-http2-mitigation-review.md) accepts the base listener configuration and real HTTP/2 rejection, HTTP/1 request and LiveView WebSocket regression checks. Combined verification reports 216 doctests and 1,703 tests, zero failures, with the accepted rotation test hash preserved.

The original blocked evidence above remains accurate for its review stage. The [explicit temporary exception](bandit-http2-audit-exception.md) now permits committing with only the named, still-disclosed advisory **while every exception condition holds**, including disabled HTTP/2 on every configured application listener and a fresh live patch/advisory check immediately before each commit. The raw dependency audit remains failing; this is conditional commit eligibility, not a clean audit or a patched package. Unrelated findings, stale/unavailable metadata, failed mitigation, or availability of a published fixed release block reliance on the exception. No deployment is implied.
