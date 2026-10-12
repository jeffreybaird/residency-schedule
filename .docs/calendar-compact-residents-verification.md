# Compact calendar resident rows verification

Authoritative workflow-runner evidence, October 12, 2026. No source or test edits
were made by the runner. Local runtime remains Elixir 1.19.5 on OTP 29.0.1;
repository-pinned OTP 28.5.0.7 is not installed locally. Mix commands require
native escalation for local PubSub sockets and the test database.

## Red contract

```sh
MIX_ENV=test mix test test/residency_schedule_web/live/calendar_rotation_groups_test.exs test/residency_schedule_web/live/daily_assignment_integration_test.exs --seed 0
```

Exit 2: **1 doctest, 19 tests, 8 failures**, 0.8 seconds. The expected failures
show duplicate nested rotation labels, retained card structure, and absent
parenthetical daily tasks beside resident names. Notes, escaping, filtering,
coverage and activity-only residents remain covered by the contract.
Log: `/tmp/calendar-compact-red.log`.

Reviewer-accepted pre-implementation test hashes, verified unchanged after focused
green:

```text
41f00d81ce00d63658c1a560abe53905b34841af6013d464ae9639ae9fdb53d7  test/residency_schedule_web/live/calendar_rotation_groups_test.exs
d79c20dea141cd4ff04aab49a70394988ad0a397cae97077005de382a00067de  test/residency_schedule_web/live/daily_assignment_integration_test.exs
```

## Green verification

Source and test owners formatted their owned files before the runner executed
read-only checks.

- Focused command: the two red-phase files plus
  `test/residency_schedule_web/live/calendar_live_test.exs`, using
  `MIX_ENV=test mix test ... --seed 0`. Exit 0; **1 doctest, 60 tests, 0 failures**,
  6.7 seconds. Log: `/tmp/calendar-compact-focused-green.log`.
- `MIX_ENV=test mix format --check-formatted`: exit 0.
- `MIX_ENV=test mix compile --warnings-as-errors`: exit 0.
- `MIX_ENV=test mix deps.unlock --check-unused`: exit 0, no lockfile edits.
- `MIX_ENV=test mix credo --strict`: exit 0; 270 files, 2,201 modules/functions,
  no issues. Log: `/tmp/calendar-compact-checks.log`.
- `git diff --check`: exit 0.
- `MIX_ENV=test mix test --seed 298741`: exit 0; **196 doctests, 1,446 tests,
  0 failures**, 50.3 seconds. Log: `/tmp/calendar-compact-full-green.log`.
  The private-data sentinel logged during the suite is intentional test output.
- Accepted test hashes remained unchanged after the full suite.

## Security scope

The current dependency/runtime review is recorded in
[qgenda-oct12-security-review.md](qgenda-oct12-security-review.md). This follow-up
changes calendar presentation, with no dependency or runtime upgrade. The known
local OTP advisories remain applicable; functional test success does not establish
a clean host runtime or verify production's runtime.
