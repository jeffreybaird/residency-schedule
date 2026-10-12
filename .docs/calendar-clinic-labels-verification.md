# Calendar clinic labels verification — October 12, 2026

Authoritative workflow-runner evidence. No source/test edits by the runner.
Runtime: Elixir 1.19.5 on local OTP 29.0.1. Mix commands require native escalation
for localhost PubSub sockets and the test database.

## Accepted contract and red evidence

```sh
MIX_ENV=test mix test test/residency_schedule_web/live/calendar_clinic_labels_test.exs --seed 0
```

Exit 2: **6 tests, 5 expected failures**, 0.5 seconds. Exact AM/PM clinic pairing
and redundant continuity-note hiding failed; preservation safeguards passed.
Log: `/tmp/calendar-clinic-red.log`.

Reviewer accepted the contract before implementation. It covers three exact clinic
prefixes in day/month/week details; stable first-appearance ordering; lone, different
site/date/person and qualified-task exclusions; exact continuity-note suppression;
meaningful escaped notes; unchanged raw data and resident-page rendering.

Accepted SHA-256:

```text
fccdcdafcc2bdfcdc86197cb52c641b5c56688228921c59a878f666a444ee6f2  test/residency_schedule_web/live/calendar_clinic_labels_test.exs
```

## Green verification

Source and test owners formatted their files before read-only runner checks.

```sh
MIX_ENV=test mix test test/residency_schedule_web/live/{calendar_clinic_labels,calendar_rotation_groups,daily_assignment_integration,calendar_redundant_assignments,calendar_highland_assignments,calendar_live,resident_specific_rotations}_test.exs --seed 0
```

- Focused regressions: exit 0; **5 doctests, 154 tests, 0 failures**, 13.0 seconds.
  Log: `/tmp/calendar-clinic-focused-green.log`.
- `MIX_ENV=test mix format --check-formatted`: exit 0.
- `MIX_ENV=test mix compile --warnings-as-errors`: exit 0.
- `MIX_ENV=test mix deps.unlock --check-unused`: exit 0.
- `MIX_ENV=test mix credo --strict`: exit 0; 271 files, 2,205 modules/functions,
  no issues. Log: `/tmp/calendar-clinic-checks.log`.
- `MIX_ENV=test mix test --seed 298741`: exit 0; **200 doctests, 1,529 tests,
  0 failures**, 40.5 seconds. Log: `/tmp/calendar-clinic-full-green.log`.
  The private-data sentinel is intentional test output.
- Accepted test hash remained unchanged after final execution.
- `git diff --check`: exit 0.

No JavaScript/assets changed; the preceding verified JavaScript tests and asset
build were not repeated for this Elixir-only presentation change.

## Security scope

Dependency versions remain unchanged since the same-session
[security review](qgenda-oct12-security-review.md). Known host OTP findings remain
applicable; functional success does not establish a clean host runtime or verify
production's runtime. No production writes were performed by the runner.
