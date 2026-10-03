# Activity search verification

Authoritative runner evidence, 2026-10-03. No source or test edits by the runner.
No production writes, real-data imports, or deployment were performed.

## Accepted red

- `MIX_ENV=test mix test test/residency_schedule/contexts/activity_search_test.exs test/residency_schedule_web/live/activity_search_live_test.exs`
  exited 2: **1 doctest, 14 tests, 14 failures**, seed 677181. The search API and
  activity-search UI were absent.
- `MIX_ENV=test mix test test/residency_schedule_web/live/activity_search_invalid_event_test.exs`
  exited 2: **1 test, 1 failure**, seed 248053. Forged non-scalar event fields
  were not rejected with an error and cleared results as required.

The reviewer independently accepted each contract before the corresponding
source work. The spec writer corrected two Credo-only offenses (numeric literal
formatting and equivalent nonempty assertion), with renewed reviewer acceptance.
Behavioral assertions were not weakened.

## Final green

- Exact final source: `MIX_ENV=test mix test`, normal parallelism
  (`max_cases: 16`), exited 0: **187 doctests, 1,395 tests, 0 failures**,
  seed 967873, 29.6 seconds. No serialization, exclusions, or retries.
- `MIX_ENV=test mix format --check-formatted`: exit 0.
- `MIX_ENV=test mix compile --warnings-as-errors`: exit 0.
- `MIX_ENV=test mix deps.unlock --check-unused`: exit 0; lockfile unchanged.
- `MIX_ENV=test mix credo --strict`: exit 0; 256 files,
  2,119 modules/functions, no issues.

Final accepted SHA-256 hashes:

```text
cdb6183f84946522efae8f8cfc7b1bdcde681a3f89a6c56166a4563439cd1a3e  test/residency_schedule/contexts/activity_search_test.exs
36af552abcda473763852cd7dcca35b0fb3d5731fac72991f71f870da95d7674  test/residency_schedule_web/live/activity_search_live_test.exs
cd3492055491cc8471625e95e3b900b40411b1edd556eeeead31e049e6e660b3  test/residency_schedule_web/live/activity_search_invalid_event_test.exs
38ee78255b47e1c8ba2dfa8d2112de5c594344aca0be1fc82aeb154232f7e04e  test/support/activity_search_fixtures.ex
```

Verification includes database-backed context and LiveView tests. The runner did
not perform separate browser visual QA. See [security review](qgenda-security-review.md)
for dependency and pre-existing runtime findings; functional green does not
establish a clean runtime or production deployment.
