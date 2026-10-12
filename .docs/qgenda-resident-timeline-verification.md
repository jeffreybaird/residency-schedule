# QGenda resident timeline verification — October 12, 2026

Authoritative evidence recorded by the workflow runner. The runner did not edit
source or tests. Local runtime: Elixir 1.19.5 (compiled with OTP 28), executing on
Homebrew Erlang/OTP 29.0.1 / ERTS 17.0.1. The repository pins OTP 28.5.0.7, which
was not installed in the usual local tool-manager locations. No runtime was
installed or upgraded by the runner.

Mix required native sandbox escalation because its local PubSub TCP socket was
blocked with `:eperm`. Test commands use only the local test database.

## Red evidence and accepted contract

Command for focused contract runs:

```sh
MIX_ENV=test mix test test/residency_schedule_web/live/resident_imported_schedule_test.exs --seed 0
```

- Initial contract: exit 2; 6 tests, 6 expected failures; 1.4 seconds.
  Log: `/tmp/qgenda-resident-red.log`.
- Reviewer-refined contract: exit 2; 7 tests, 7 expected failures; 1.7 seconds.
  Log: `/tmp/qgenda-resident-red-v2.log`.
- Initial implementation: exit 2; 7 tests, 1 failure. The failing statistics
  assertion revealed a contract error: existing arithmetic counts rotation days,
  not rotation blocks. Two seven-day rotations correctly contribute 14 days.
  Log: `/tmp/qgenda-resident-green.log`.
- The orchestrator authorized preserving day arithmetic and explicitly labeling
  it Rotation Days. The spec writer revised the contract with renewed reviewer
  acceptance, registered the Show module doctests, and added activity-only/no-slot
  and genuinely empty-resident coverage. Before source corrections this run exited
  2: 3 doctests, 9 tests, 2 failures (statistics wording and empty state), 0.6 seconds.
  Log: `/tmp/qgenda-resident-contract-v3.log`.

The final contract checks imported Saturday night call, literal tasks alongside
base rotations, exact OFF date spans, tasks through historical resident appearances,
daily-assignment filtering and forged coworker events, unchanged rotation-day
arithmetic, escaped notes, no-slot activities, and the empty state.

The reviewer accepted the final semantic DOM assertion correction and independently
reviewed the implementation. Final accepted test SHA-256, verified unchanged after
implementation and focused green (the existing rotation-support test received
a reviewer-accepted wording-only adaptation; its numeric assertion remains 1):

```text
e380d2fd92c33ffc814dc4e857ab0cfc79933586a1060fcd3e22f1b776daeac1  test/residency_schedule_web/live/resident_imported_schedule_test.exs
28c58b71658aa87a63dac40f19c295ab250a8cddbedea2cf9a23d4ad0974b35b  test/residency_schedule_web/live/rotation_support_live_test.exs
```

Earlier hashes for traceability: initial six-test contract
`5e5207ab8f17d6ca7a379aad2ac4fd8137f22facd6538af90b3d9ad0aaf795fa`;
seven-test contract `2be6841407fdb85a20166a88ad1d47ae10942b8aa439a523151d033f197717d8`;
revised day-count contract before semantic empty-state selector correction
`8b7f168d8d18f3853e1fd30452c1050b07f1054a77a428d0cb4dce2414d275a8`.

## Green verification

Source and test owners ran scoped `mix format --force` first. The runner used
read-only precommit equivalents rather than the correcting alias.

Focused command:

```sh
MIX_ENV=test mix test test/residency_schedule_web/live/resident_imported_schedule_test.exs test/residency_schedule_web/live/resident_live_test.exs test/residency_schedule_web/live/daily_assignment_integration_test.exs test/residency_schedule_web/live/qgenda_details_test.exs test/residency_schedule/contexts/detailed_schedules_test.exs test/residency_schedule/importer/qgenda_crosswalk_test.exs --seed 0
```

- Focused regressions: exit 0; **7 doctests, 82 tests, 0 failures**, 5.5 seconds,
  seed 0. Includes the final contract's 3 doctests and 9 tests.
  Log: `/tmp/qgenda-resident-focused-green.log`.
- `MIX_ENV=test mix format --check-formatted`: exit 0.
- `MIX_ENV=test mix compile --warnings-as-errors`: exit 0.
- `MIX_ENV=test mix deps.unlock --check-unused`: exit 0; no lockfile edits.
- `MIX_ENV=test mix credo --strict`: exit 0; 270 files, 2,198 modules/functions,
  no issues. Log: `/tmp/qgenda-resident-checks.log`.
- Initial full suite: exit 2; 196 doctests, 1,446 tests, 1 failure, 62.1 seconds,
  seed 298741. The existing rotation-support test selected the old statistics
  tooltip. The spec writer updated only its name and selector for the accepted
  Rotation Days wording, preserving its asserted count of 1; reviewer accepted.
  Log: `/tmp/qgenda-resident-full-green.log`.
- Final two-file focused run after selector correction: exit 0; 3 doctests,
  11 tests, 0 failures, 1.2 seconds, seed 0.
  Log: `/tmp/qgenda-resident-final-targeted.log`.
- Final `MIX_ENV=test mix format --check-formatted`: exit 0.
- Final `MIX_ENV=test mix test --seed 298741`: exit 0; **196 doctests, 1,446 tests,
  0 failures**, 46.3 seconds. Log: `/tmp/qgenda-resident-full-final.log`.
  The logged private-data sentinel is intentional test output, not a failure.

## Security scope

See [the independent security review](qgenda-oct12-security-review.md). Its current
advisory scan identified Decimal 3.1.1 (CVE-2026-97853 / GHSA-6c27-994x-c52f), patched
in 3.1.2; the implementer updated the lockfile to 3.1.2 before these test runs.
Pre-existing host OTP 29.0.1 findings remain documented there, including affected
components, patched versions, and exposure uncertainty. Functional success does
not establish a clean host runtime or verify production's installed runtime.
