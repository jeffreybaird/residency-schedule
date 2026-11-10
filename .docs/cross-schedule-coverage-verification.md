# Cross-schedule coverage read scope

Recorded October 28, 2026 on baseline
`d801c557c90884a3d2101057eb8fb9a2ea5b8228`, following PR #98.

Schedule-scoped override queries previously selected only the original resident's
schedule. Incoming coverage was invisible to gap filling and bulk effective
reads: a covering resident could appear on an imported assignment or their own
rotation instead of coverage, while individual reads correctly showed coverage.

Both complete and date-range override queries now include the original or the
covering membership's schedule. Date bounds remain inclusive. Existing projection
occupancy suppresses a covered gap fill; effective reads displace the covering
resident's own duty while retaining the projected baseline for other uses.
Bulk effective reads load metadata from each distinct original schedule once,
reusing the current schedule projection, so incoming night coverage keeps the
previously fixed timing and UID behavior.

Range-scoped coworker rows suppress a covering resident's own duty. This does not
claim that every schedule-filtered consumer now displays foreign service rows:
those consumers still need the original rotation in their input. Consumer-output
comparison remains a later Phase 3 delivery.

## Contract and evidence

The spec writer added seven synthetic regression tests covering original and
covering schedules, neighboring gap-fill dates, own-duty precedence, unrelated
schedule isolation, original-person identity, unchanged stored rows, inclusive
range endpoints, coworker suppression and incoming canonical-night metadata.
Reviewer-accepted SHA256 for
`test/residency_schedule/cross_schedule_coverage_test.exs`:
`f773a07aa6773739a573d97c1e78a11a826d03132b067850d97338dfacac3f89`.

Runner red before implementation: `mix test
test/residency_schedule/cross_schedule_coverage_test.exs`; seven tests, six
expected behavior failures, seed 777397. No setup or compile failures.

Focused green included the new contract, Strong night projection, resident
schedule data/performance and schedule-cache integration: one doctest, 37 tests,
zero failures, seed 765932. Frozen test hash remained unchanged.

Source and test owners ran forced formatting on their owned files. Independent
review confirmed that widened queries have only read callers, joins cannot
multiply override rows, and original schedule projections are batched. Fresh
`mix hex.audit` found no retired or advisory packages; this is Hex advisory
coverage, not a comprehensive OS or production exposure scan. Audit entries for
owned test formatting have no violations.

No database migration, production command, deployment, data write or consumer
read-version switch occurred.

## Final verification

- Full `mix test`: 302 doctests, 1972 tests, zero failures, seed 261131,
  61.4 seconds.
- `mix format --check-formatted`, `MIX_ENV=test mix compile --warnings-as-errors`,
  `mix deps.unlock --check-unused`: exit zero.
- `mix credo --strict`: 379 files, 3057 modules/functions, no issues.
- Accepted test SHA256 unchanged.
