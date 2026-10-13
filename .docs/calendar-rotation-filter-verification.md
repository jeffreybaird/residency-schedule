# Calendar rotation filter verification

When one or more rotation filters are selected, day views and day modals show
only those rotation groups. Unclassified assignments from other residents must
not bypass the filter. Assignments attached to a resident in a selected rotation
remain visible beside that resident. Clearing the filter restores all groups.

## Verification

Authoritative runner evidence; no source/test edits by the runner. Local runtime:
Elixir 1.19.5 on OTP 29.0.1. Mix requires native escalation for local PubSub
sockets and the test database. Source/test owners formatted their owned files.

Red command:

```sh
MIX_ENV=test mix test test/residency_schedule_web/live/calendar_rotation_groups_test.exs test/residency_schedule_web/live/calendar_highland_assignments_test.exs --seed 0
```

Exit 2: **15 tests, 2 expected failures**, 1.2 seconds.
Log: `/tmp/calendar-filter-red.log`. Reviewer acceptance preceded implementation.

Focused green command:

```sh
MIX_ENV=test mix test test/residency_schedule_web/live/{calendar_rotation_groups,calendar_highland_assignments,calendar_live,daily_assignment_integration,qgenda_schedule_gaps}_test.exs --seed 0
```

- Focused: exit 0; **2 doctests, 77 tests, 0 failures**, 6.9 seconds.
  Log: `/tmp/calendar-filter-focused-green.log`.
- `MIX_ENV=test mix format --check-formatted`: exit 0.
- `MIX_ENV=test mix compile --warnings-as-errors`: exit 0.
- `MIX_ENV=test mix deps.unlock --check-unused`: exit 0.
- `MIX_ENV=test mix credo --strict`: exit 0; 275 files, 2,248 modules/functions,
  no issues. Log: `/tmp/calendar-filter-checks.log`.
- `MIX_ENV=test mix test --seed 298741`: exit 0; **205 doctests, 1,551 tests,
  0 failures**, 41.4 seconds. Log: `/tmp/calendar-filter-full-green.log`.
  The private-data sentinel is intentional test output.
- Both accepted test hashes below remained unchanged after final execution.
- `git diff --check`: exit 0.

No JavaScript/assets changed; no unrelated asset checks repeated.

## Security

Dependency and runtime evidence is documented in the
[October 12 security report](qgenda-oct12-security-review.md). Final review must
state whether it remains applicable and retain its runtime limitations.

## Independent review

The reviewer accepted the test contract after the runner's 15-test red run
reported two expected filter failures. The changed Highland expectation reflects
the user's new requirement; its clear-filter restoration assertion preserves
unfiltered behavior. The new integration case covers day, month modal, week modal,
multiple selected rotations, unrelated residents, and selected residents' clinic
tasks and notes.

The complete source change removes only the unconditional nil-category bypass
after day grouping. With no filter, all groups remain visible; with a filter,
group membership must match a selected type. Existing attachment of unclassified
details to selected residents remains unchanged. No implementation blocker was
found. Final acceptance follows the runner's green evidence: 205 doctests and
1,551 tests pass with zero failures; required format, compilation, dependency,
Credo, and diff checks pass. Both accepted test hashes remain unchanged.

Accepted test hashes:

- `calendar_rotation_groups_test.exs`: `c675b5a1c9b08510d7cdf1e13b579ec1d6a057fb85dd09b868965032062aec16`.
- `calendar_highland_assignments_test.exs`: `9500011a628fe932075fce4de2b6deafe60e9f6c7f6145c9840cdbbaf4a8e47c`.

The audit adds one owner-scoped writer-formatting entry with no violations.
Dependency manifests and lockfile are unchanged, so the same-session advisory
evidence remains applicable. Decimal 3.1.2 fixes GHSA-6c27-994x-c52f /
CVE-2026-97853 (affected below 3.1.2); the post-upgrade OSV scan found no matches
among 51 locked Hex packages. Forty pre-existing advisories remain on the active
local OTP 29.0.1 runtime, individually documented with component versions and
exposure conditions in the linked report. Patched release options are 29.1.1,
28.5.0.7, or 27.3.4.18. Repository pins specify 28.5.0.7; actual production runtime
and endpoint-specific exposure remain unverified. Those host findings are not
resolved by this change.
