# Consecutive rotation merge verification

## Environment and procedure

- Runner owns no source or test edits. Source/test owners perform format corrections; runner uses read-only checks.
- Runtime loaded with `source /workspace/.setup/activate.sh`: Elixir 1.19.5, Erlang/OTP 28 (ERTS 16.4.0.6).
- Existing local PostgreSQL 17 data directory restarted with `pg_ctl -D /workspace/.setup/postgres -l /workspace/.setup/postgres.log -o '-h 127.0.0.1 -k /workspace/.setup/postgres-socket' -t 20 start`; readiness confirmed on localhost:5432. No production data accessed.
- Default sandbox disallows Mix PubSub local TCP sockets (`:eperm`). Checks run with additional network permission for local sockets.
- Read task help before `test`, `compile`, `format`, `deps.unlock`, `credo`, and `hex.audit`.
- `mix.exs` precommit alias runs format correction, warnings-as-errors compile, unused dependency unlock, and tests. Equivalent runner checks use `format --check-formatted` and `deps.unlock --check-unused` to avoid mutations.
- CI requires warnings-as-errors compilation and the full test suite. Credo is an additional static analysis check.

## Security audit

`MIX_ENV=test mix hex.audit` exited 1 with current advisory metadata:

- `bandit 1.12.5`: EEF-CVE-2026-105659 / CVE-2026-105659 / GHSA-69m6-wcv4-rwcf (HIGH). HTTP/2 blocked-send deadlines can reset on every WINDOW_UPDATE, allowing a trickle to pin stream processes. Reviewer is independently assessing fix availability and exposure. No advisories suppressed.

## Test contract and outcomes

- Baseline: `MIX_ENV=test mix test test/residency_schedule_web/live/resident_live_test.exs` passed (33 tests, 0 failures).
- Regression contract: `test/residency_schedule_web/live/resident_adjacent_rotations_test.exs`, SHA256 `8c2f863b8ea9368172726eee9044e1c8d89fa92796e56fed9d4137a0a3fac330`.
- Authoritative red: `MIX_ENV=test mix test test/residency_schedule_web/live/resident_adjacent_rotations_test.exs` exited 2; 8 tests, 3 assertion failures, seed 830125. Failures demonstrate absent merging for a base three-slot chain, identical specific-task spans, and a chain interleaved with an independent concurrent rotation. Remaining five tests pass. No fixture or runtime failures. Full local log: `/tmp/rotation-merge-red.log`.
- Reviewer requested two additional regressions for fallback imported-task identity and unmatched daily activity preservation. Final accepted contract SHA256: `ca0f193a1cbbcbad4040666e58ec74bfd2457d7ed9df345f2b8adf55d6d6fb0a`.
- Refreshed authoritative red before implementation: same command exited 2; 10 tests, 4 expected merge assertion failures, seed 680309. Added daily-activity test fails first on required merged rotation selector; distinct fallback labels pass baseline. No fixture/runtime failures. Full local log: `/tmp/rotation-merge-red-final.log`.

## Final checks

- Focused green: regression file plus `resident_live_test.exs`, `resident_imported_schedule_test.exs`, `resident_specific_rotations_test.exs`, `resident_rotation_exceptions_test.exs`, and `resident_performance_test.exs`: **10 doctests, 75 tests, 0 failures**, seed 31810. Full local log: `/tmp/rotation-merge-focused-green.log`.
- Source owner ran `mix format --force` on owned source; test writer ran it on the regression file. Runner's global `MIX_ENV=test mix format --check-formatted`: **pass**.
- `MIX_ENV=test mix compile --warnings-as-errors`: **pass**.
- `MIX_ENV=test mix deps.unlock --check-unused`: **pass**, no lock mutation.
- `MIX_ENV=test mix credo`: **pass**, 57 checks on 315 files, no issues.
- `git diff --check`: **pass**.
- Final accepted test SHA256 remains `ca0f193a1cbbcbad4040666e58ec74bfd2457d7ed9df345f2b8adf55d6d6fb0a` after implementation and formatting.
- Full suite `MIX_ENV=test mix test`: **pass**, 216 doctests, 1696 tests, 0 failures in 64.7 seconds, seed 75481. Local log: `/tmp/rotation-merge-full-test.log`. Existing negative `Date.range/2` warnings and test-local `:eprof` warnings were emitted; tests still passed. No source/test corrections were made by the runner.
- JavaScript and asset build checks were not rerun: this change edits only server-side resident rotation row projection and its tests.
- Functional checks are green, but the required dependency audit remains **failing** on the pre-existing Bandit advisory with no published patched release. Changes remain uncommitted because that required gate has not passed. See [independent security review](consecutive-rotation-merge-security-review.md) for exposure uncertainty and remediation options.

## Authorized mitigation follow-up — October 15, 2026

After the original blocked result above, the user explicitly authorized disabling
HTTP/2 and a narrow temporary audit exception with a fresh patch check before
every commit. The [exception](bandit-http2-audit-exception.md) conditionally permits
the disclosed Bandit finding; it does not make the raw audit pass. Real listener
tests confirm HTTP/2 rejection with HTTP/1 and LiveView WebSocket upgrades intact.
The combined final suite passes: **216 doctests, 1,703 tests, zero failures**.
See [mitigation verification](bandit-http2-mitigation-verification.md). The
original rotation test hash is unchanged. Commit eligibility now depends on all
exception conditions and a fresh live patch check recorded for each commit.
