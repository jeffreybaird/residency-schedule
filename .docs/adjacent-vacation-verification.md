# Adjacent vacation verification

## Scope and environment

Follow-up on branch `codex/merge-adjacent-vacation` from main `636131e`. Consecutive visible Vacation spans should merge even when roster weekdays and imported weekends have different hidden source metadata. Synthetic April 5–18, 2027 data only; no production resident data.

Runner edits no source or tests. Checks use `source /workspace/.setup/activate.sh` (Elixir 1.19.5 / OTP 28), network permission for Mix and real protocol listener sockets, and existing isolated local PostgreSQL on localhost:5432. Relevant Mix task help was read earlier in this session.

Frozen prior contracts:

- Rotation: `test/residency_schedule_web/live/resident_adjacent_rotations_test.exs`, SHA256 `ca0f193a1cbbcbad4040666e58ec74bfd2457d7ed9df345f2b8adf55d6d6fb0a`.
- Protocol mitigation: `test/residency_schedule_web/http_protocol_security_test.exs`, SHA256 `ad6e609c6f1fefd21f3b060d35a836535a9226b5a80ec3ab8a12a2d6d34acc30`.

## Authoritative test evidence

- Regression contract: `test/residency_schedule_web/live/vacation_adjacent_rotations_test.exs`, SHA256 `a42c6c62939286bbba773c5bf9a4a4363bc9a02a84a092140ec91421bd9c0c89`.
- Authoritative red: `MIX_ENV=test mix test test/residency_schedule_web/live/vacation_adjacent_rotations_test.exs` exited 2: **3 tests, 2 expected failures**, seed 879638. The mixed-source April 5–18 merged Vacation selector is absent; the gap test's second week plus weekend merged selector is also absent. Different visible duty labels remain separate and pass. No fixture/runtime failures. Local log: `/tmp/adjacent-vacation-red.log`. Reviewer accepted behavioral assertions before source implementation.

## Final checks

Focused suite command:

```sh
MIX_ENV=test mix test test/residency_schedule_web/live/vacation_adjacent_rotations_test.exs test/residency_schedule_web/live/resident_adjacent_rotations_test.exs test/residency_schedule_web/http_protocol_security_test.exs test/residency_schedule_web/live/resident_live_test.exs test/residency_schedule_web/live/resident_imported_schedule_test.exs test/residency_schedule_web/live/resident_specific_rotations_test.exs test/residency_schedule_web/live/resident_rotation_exceptions_test.exs test/residency_schedule_web/live/resident_performance_test.exs
```

- First focused run after minimal key change: 10 doctests, 85 tests, **1 failure** in existing `resident_specific_rotations_test.exs:53`: merged base/imported Vacation span loses the expected specific-label element. New Vacation regressions and prior adjacent/protocol contracts pass. Routed to implementer/reviewer; no accepted tests changed by runner. Local log: `/tmp/adjacent-vacation-focused-green.log`.
- Test writer revised that existing Vacation case for the explicitly authorized full December 28–January 3 span and 7-day duration, absence of old partial ranges, preserved notes, and an independent gapped base Vacation span for the original exact pill style comparison. Ambulatory behavior unchanged. Reviewer renewed acceptance. Focused eight-file suite then passed: **10 doctests, 85 tests, 0 failures**, seed 187463. Local log: `/tmp/adjacent-vacation-focused-final.log`.
- A new constant-type test compiler warning in that revised case was corrected by the test writer at generation time, with reviewer renewed acceptance and unchanged assertions. Final specific-test contract SHA256: `0aa9d3b3f66dc5dc1ade083be61e5d9ba6b617e0cbfbaece8f907360d5d0dcb8`. Final targeted `MIX_ENV=test mix test test/residency_schedule_web/live/resident_specific_rotations_test.exs`: **7 doctests, 16 tests, 0 failures**, seed 593414, no warnings. Local log: `/tmp/adjacent-vacation-specific-final.log`.
- `MIX_ENV=test mix compile --warnings-as-errors` and `MIX_ENV=test mix deps.unlock --check-unused`: pass.
- Final `MIX_ENV=test mix format --check-formatted`: pass; `MIX_ENV=test mix credo`: pass, 57 checks on 317 files, no issues.
- Full suite `MIX_ENV=test mix test`: **pass**, authoritative exit 0, **216 doctests, 1706 tests, 0 failures** in 82.0 seconds. Local log: `/tmp/adjacent-vacation-full-test.log`. Existing negative `Date.range/2` and test-local `:eprof` warnings remain; the revised Vacation test's warning is absent.
- All four accepted hashes remain unchanged after final verification: new Vacation regression, renewed specific-rotation contract, frozen original adjacent-rotation contract, and frozen protocol contract. `git diff --check`: pass.
- Assets/JavaScript checks were not rerun because no frontend asset source changed. No production data was read or modified.
- The raw dependency audit is a separate check: only the [named temporary Bandit exception](bandit-http2-audit-exception.md) authorizes its disclosed finding, with passing protocol mitigation and a fresh live package check immediately before each commit. Reviewer/orchestrator record those checks. No commit, push, or deployment is performed by the runner.
