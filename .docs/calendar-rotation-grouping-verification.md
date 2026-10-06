# Calendar rotation grouping verification

Authoritative runner evidence, 2026-10-06. The runner made no source or test
edits. Verification used the local test database with Elixir 1.19.5 / OTP 29;
no production data writes or deployment occurred.

## Red contract

`MIX_ENV=test mix test test/residency_schedule_web/live/calendar_rotation_groups_test.exs`
exited 2 before implementation: **6 tests, 6 failures**, seed 16690,
normal parallelism (`max_cases: 16`). Each failure identified missing rotation
groups; fixtures and QGenda imports succeeded. Before acceptance, the coverage
expectation was corrected to preserve the existing suppression of a covering
resident's own base rotation.

The accepted preimplementation SHA-256 was
`90856860cfc7739b0c2212c73ba60742ac10f05c0083b3cb4dc1843e43491c8b`.
It remained unchanged through implementation. Independent review then requested
an additional test for concurrent rotation types, duplicate same-type entries,
resident counts, scoped details, and unique DOM IDs; the original six tests were
unchanged and the reviewer renewed acceptance.

## Final green

- The regression, existing calendar, daily-assignment integration, and QGenda
  detail suites passed before the seventh test was added: **1 doctest, 67 tests,
  0 failures**, seed 357135, exit 0.
- Final regression file: **7 tests, 0 failures**, seed 621440, exit 0.
- Final `MIX_ENV=test mix test`: **193 doctests, 1,437 tests, 0 failures**,
  seed 280229, `max_cases: 16`, 35.3 seconds, exit 0.
- `MIX_ENV=test mix format --check-formatted`: no errors. The final test-file
  formatting check also exited 0 after the additional regression.
- `MIX_ENV=test mix compile --warnings-as-errors`: no errors.
- `MIX_ENV=test mix deps.unlock --check-unused`: no errors; no lockfile edits.
- `MIX_ENV=test mix credo --strict`: exit 0; 269 files, 2,189 modules/functions,
  no issues. Source remained unchanged after these static checks.

Source and test owners ran their scoped `mix format --force` corrections before
the runner's read-only checks. Final accepted test SHA-256:

```text
5b31d7a80c3b62a0c615e22429f8136f45509c4b2b0dabe21234019ae23a60a1  test/residency_schedule_web/live/calendar_rotation_groups_test.exs
```

## Security and scope

The independent reviewer ran `mix hex.audit`: exit 0, no retired packages.
The reviewer fetched the current GitHub Erlang advisory feed with
`curl --fail --silent --show-error` from
`https://api.github.com/advisories?ecosystem=erlang&per_page=100`, including its
next page, on 2026-10-06 at 13:19 UTC. Across 121 advisory records and 60 matching
installed-package ranges, no vulnerable locked dependency versions were found.
The reviewed lockfile SHA-256 was
`125be7cc5fc6f1818e6d919d5594e1ca1a4977d0d23f57f38050951cf9a99928`.
Production OTP and host packages were not audited; this is not a production
runtime security clearance.

The reviewer checked the current task's audit entries and found no ownership
violations; older ambiguous entries predate this change. Browser visual
inspection was not performed by the runner. Unrelated README and LICENSE work
was preserved.
