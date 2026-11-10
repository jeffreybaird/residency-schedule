# Coverage calendar source metadata

Recorded October 28, 2026, following the isolated calendar prerequisite PR #97.
Baseline: `b873a5e6c25a8960c55905fea4fabd60714eab44`.

## Demonstrated defect and preserved behavior

A canonical Strong night block on November 2–6 has projected evening-first
metadata on November 3. Its covered owner segment retains that metadata, but
its covering resident's segment previously discarded it, moving the calendar
start to November 2 at 18:00. Coverage now inherits the applicable projected
metadata per covered date; November 3 coverage starts November 3 at 18:00.

The plan's suspected rotation-type mismatch was not established: existing
policies deliberately preserve stored types on override-protected dates.
Those types remain unchanged. Coverage spanning projected and restored dates
is split where metadata differs, retaining the original coverage start as
`calendar_start_date` so existing timed-event UIDs stay stable.

The November 5–6 fixture deliberately retains the legacy restored Friday
semantics: projected November 5 and unsourced restored November 6 events can
share the same evening interval with different existing UIDs. This change fixes
metadata parity, not overlap estimation or protected-date policy.

Resident reads reuse their complete schedule projection; foreign coverage
loads each distinct original schedule once. Bulk schedule reads reuse their
existing projection. The separately known incoming cross-schedule override
scope defect remains for a subsequent isolated change.

## Workflow evidence

The spec writer added canonical-night and mixed-boundary coverage tests with
explicit metadata, timestamp and UID expectations, read-path parity, owner feed
exclusion, and unchanged stored rotation/override assertions. Existing protected
date controls were retained. Reviewer-accepted initial test SHA256:
`test/residency_schedule/strong_night_projection_test.exs`
`da78f5ac4bc9f613214a5d62079e0a0f65205c3e03733d5b8c097c6342410fb9`.

Runner red: `mix test test/residency_schedule/strong_night_projection_test.exs`;
1 doctest, 13 tests, two expected failures, seed 985634. Single-day coverage had
nil source date instead of November 1; mixed-date coverage had nil on both dates
instead of projected/restored metadata. Source was unchanged during that run.

Runner focused green before review additions: Strong night projection,
resident schedule data and resident performance tests; 1 doctest, 18 tests,
zero failures, seed 714984, accepted hash unchanged.

Independent review requested explicit expected metadata for foreign-schedule
coverage, because parity alone could pass when both functions share the same
implementation. It also requested documenting the virtual identity field and
replacing the touched database function's fallback-only doctest with an explicit
database exemption backed by successful integration tests.

No production data, migration, deployment or read-version routing changed.
All fixtures are synthetic. Fresh `mix hex.audit` reported no retired or
security-advisory packages; its coverage is limited to Hex advisories.

The added foreign-schedule case is a post-implementation regression; the original
two pre-implementation failures remain the red evidence. The reviewer accepted
the additional assertions without changing the prior expectations. Final accepted
SHA256 for the same test file:
`36502a391ba10cc90badee53df10b37cc2924d087e8a9a0e48e297408706a30e`.
Final focused run: 1 doctest, 19 tests, zero failures, seed 304393.

During the first full-suite run the source owner updated documentation and the
spec writer added the review-requested regression. The Bash audit therefore
recorded their changes against the overlapping runner command as ambiguous
violations. They were owned edits, not runner edits; the final verification runs
after those changes. The audit log is retained with this change.

## Final verification

After all review additions and source documentation corrections:

- Full `mix test`: 302 doctests, 1965 tests, zero failures, seed 511744,
  59.3 seconds.
- `mix format --check-formatted`, `MIX_ENV=test mix compile --warnings-as-errors`,
  `mix deps.unlock --check-unused`: exit zero.
- `mix credo --strict`: 378 files, 3050 modules/functions, no issues.
- Final accepted test hash unchanged.

No dependency upgrade was needed. Independent review accepted the retained
protected-date types and calendar UID identity, and classified the audit entry
as concurrent owned edits rather than a runner ownership violation.
