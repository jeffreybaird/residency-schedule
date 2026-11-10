# Calendar coverage summaries

Recorded October 28, 2026 on baseline
`e17e365d80dbf864df61504e279b42201183aba1`, following PR #99.

Month dots and week staffing counts previously summarized base rotations without
coverage overrides. A covering resident's displaced service remained visible,
and matching imported activities could count the original and covering person
separately. Both summary views now resolve coverage before grouping and count
active people once per service. Covered owners remain in day detail for audit,
but do not count as working in the compact staffing summary.

The existing filter order is preserved: resident and rotation filters select base
rotations before coverage is resolved. Imported activity classification remains
unchanged. An uncovered neighboring date retains its ordinary summaries.

## Contract and red evidence

The spec writer revised the existing test that intentionally pinned the legacy
defect, retaining Highland nights count one while removing displaced Oncology.
New regressions cover duplicate matching imported activity, adjacent dates,
covered-owner detail, and precoverage resident/type filters and clearing them.
Reviewer accepted SHA256 for
`test/residency_schedule_web/live/calendar_highland_assignments_test.exs`:
`b6cd7b4756fc7e22f8c94a4ca6d24c2a4ab7e997f2a114f725daa7e1591ab67f`.

Runner pre-implementation red: nine tests, three expected failures, seed 771090.
Failures demonstrated displaced Oncology remaining, wrong duplicate-person
counts and incorrect filtered summaries. No compilation or setup errors occurred.

The implementation changes only the private summary pipeline: resolve daily
coverage, omit overridden owners, and group actual resident identities. Day
detail remains unchanged. Source and test owners forced formatting independently.

Independent `mix hex.audit` found no retired or advisory packages. This checks
Hex advisories only; no production exposure or OS scan is claimed. All regression
fixtures are synthetic. No migrations, data writes, deployment or version routing
changes occurred.

The first broad focused run found one test-setup error: the adjacent Sunday
October 11 was asserted in a week anchored Saturday October 10, whose visible
range ends October 10. The spec writer opened the next week before making the
same adjacent-day assertion. Reviewer reaccepted this setup-only correction;
expected counts and all other assertions were preserved. Final accepted SHA256:
`0069da22ff5a6a44e2232b20f96fb92ac4f1f0bed1f8f28f3501fd42cc388a5f`.

## Final verification

- Focused calendar integration: 131 tests, zero failures, seed 483472.
- Full `mix test`: 302 doctests, 1974 tests, zero failures, seed 839913,
  63.4 seconds.
- `mix format --check-formatted`, `MIX_ENV=test mix compile --warnings-as-errors`,
  `mix deps.unlock --check-unused`: exit zero.
- `mix credo --strict`: 379 files, 3060 modules/functions, no issues.
- Reaccepted test SHA256 unchanged.
