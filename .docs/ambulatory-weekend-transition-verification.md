# Ambulatory / Strong weekend-night transition

## Expected behavior

The imported Monday–Friday Ambulatory block followed by Saturday–Sunday Strong
Weekend Nights displays Ambulatory Monday–Thursday and Weekend Nights Friday and
Saturday. The next Ambulatory block resumes Monday. Canonical Monday–Friday Strong
Night Float displays Sunday–Thursday, with Friday Post Call; associated
Saturday–Sunday Post Call displays Friday–Saturday. Existing aligned and arbitrary
date ranges retain their dates. Raw stored rotations, importer/edit APIs and
literal detailed activities remain unchanged, so existing schedules need no reimport.

Approved overrides retain their actual dates, original rotation identity and
participants. An explicit Friday Strong night assignment retains actual Friday
duty. Qualifying literal Friday Ambulatory night duty is Weekend Nights – Strong.
All effective read surfaces, narrow Friday/Sunday queries, and exported evening
night intervals must agree.

## Accepted test contract

The test writer owns regression tests; the implementer owns source. The final
preimplementation contract was independently accepted after authoritative RED:

```sh
source /workspace/.setup/activate.sh
MIX_ENV=test mix test test/residency_schedule/strong_night_projection_test.exs test/residency_schedule_web/live/friday_night_float_test.exs --seed 0
```

Exit 2: **1 doctest, 21 tests, 15 behavioral assertion failures, zero exception
failures**, 0.9 seconds. Log: `/tmp/ambulatory-night-transition-contract-red.log`.
Earlier intermediate RED runs exposed a missing synthetic import source and two
nil-unsafe test predicates. The writer corrected those before final acceptance;
only the final corrected RED is the authoritative behavior evidence.

Accepted SHA-256 before implementation:

```text
14721457856bbbfe321b1ff9ab02eb1f413801c21754410ecd5a60bd588ffe47  test/residency_schedule/strong_night_projection_test.exs
fe5475a9ceb590999ed968089f56830ba1f78954842a3ab77952d4d6da0e7c48  test/residency_schedule_web/live/friday_night_float_test.exs
```

The writer subsequently registered the new public projection doctest; independent
review confirmed the assertions were unchanged. The first implementation passed
the focused command (2 doctests, 21 tests) and full normal-parallel suite
(`--seed 298741`: 216 doctests, 1,678 tests, zero failures, 64.8 seconds).

Independent source review found three concrete risks: overlapping raw endpoints
could hide a canonical pair, a literal Friday assignment could cut unrelated Post
Call, and existing irregular Post Call could duplicate synthetic Friday Post Call.
A persisted calculation cache also required invalidation without a database write.
The writer added guards and a warm-cache regression. Authoritative refinement RED:

```sh
MIX_ENV=test mix test test/residency_schedule/strong_night_projection_test.exs test/residency_schedule/schedule_cache_integration_test.exs --seed 0
```

Exit 2: **1 doctest, 22 tests, four behavioral assertion failures, zero exceptions**,
1.4 seconds. Log: `/tmp/ambulatory-night-transition-refinement-contract-red.log`.
The reviewer accepted the following updated contract before source refinements:

```text
25dad6c20617521076fae041955fe876c020b4347f55853dd47b7d94c9c1b5c9  test/residency_schedule/strong_night_projection_test.exs
764f2e627fe98bba8482370748d84760bb5826380aaaf35a8e2f0616e4173dd7  test/residency_schedule/schedule_cache_integration_test.exs
```

## Final implementation

`StrongNightBoundaries.project/3` performs the in-memory canonical boundary
alignment before the existing activity and gap projections. Canonical adjacency
searches retain all candidates at each endpoint, so an unrelated overlapping raw
rotation cannot hide the matching Ambulatory/weekend pair. Explicit Friday duties
and approved override dates preserve their actual-date source identity.

Narrow range queries load seven days of boundary context and filter the projected
result back to requested dates. Normalized night spans preserve evening-date
provenance through the Friday projection and export each night from 18:00 to 06:00
the following morning. The persisted calculation cache version is 3, invalidating
old calculated grids without changing the database revision.

Source and test owners performed scoped `mix format --force`. The final focused
command adds `test/residency_schedule/schedule_cache_integration_test.exs` to the
two original regression files: exit 0, **2 doctests, 35 tests, zero failures**,
1.9 seconds. Log: `/tmp/ambulatory-night-transition-final-focused-green.log`.

Final normal-parallel full suite (`MIX_ENV=test mix test --seed 298741`): exit 0,
**216 doctests, 1,682 tests, zero failures**, 65.4 seconds. Log:
`/tmp/ambulatory-night-transition-final-full-green.log`.

All final read-only checks passed separately: `mix format --check-formatted`,
`mix compile --warnings-as-errors`, `mix deps.unlock --check-unused`,
`mix credo --strict`, and `git diff --check`. Credo inspected 313 files and 2,557
modules/functions with 69 checks and no issues. A first-pass nesting offense was
corrected by the source owner before the passing final check. No JavaScript or
asset files changed.

The three final accepted test hashes above remained unchanged after verification.
Independent review and the refreshed dependency audit are recorded in
[the review](ambulatory-weekend-transition-review.md) and its linked security
evidence.

## Runtime and review limits

The task runtime is Elixir 1.19.5 / OTP 28.5.0.7 and PostgreSQL 17.11. Mix commands
source the workspace activation and require native escalation for local sockets.
Dependency advisory and runtime evidence is recorded in
[the security review](ambulatory-weekend-transition-security-review.md).

Cloud Bash audit activation remains unverified: existing `.agent-audit/bash.jsonl`
has not gained entries during the task. Role-owned edits, frozen hashes and final
diff inspection provide the available ownership evidence; installed hook files
are not proof of active auditing.
