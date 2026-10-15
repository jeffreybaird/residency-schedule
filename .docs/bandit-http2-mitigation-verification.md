# Bandit HTTP/2 mitigation verification

## Scope and environment

User authorized disabling HTTP/2 on application Bandit endpoint listeners as a temporary mitigation while preserving HTTP/1 and WebSocket support. This does not patch Bandit or make the dependency audit clean. The [named temporary audit exception](bandit-http2-audit-exception.md) is limited to CVE-2026-105659 / GHSA-69m6-wcv4-rwcf / EEF-CVE-2026-105659. The reviewer owns fresh package advisory checks. The raw audit still exits 1 for this advisory; only that named exception allows a commit when its real listener verification and immediately-before-commit fresh live patch check conditions are met.

Runner makes no source or test edits and performs no commit, push, or deployment. Existing consecutive rotation regression contract remains frozen at SHA256 `ca0f193a1cbbcbad4040666e58ec74bfd2457d7ed9df345f2b8adf55d6d6fb0a`.

Checks use `source /workspace/.setup/activate.sh` (Elixir 1.19.5 / OTP 28) and additional network permission for Mix PubSub, local test database, and real listener sockets. PostgreSQL localhost:5432 remains the isolated existing local test database. Relevant Mix task help was read during rotation verification.

## Test contract

- Contract: `test/residency_schedule_web/http_protocol_security_test.exs`, 7 tests, SHA256 `1605a5242266f452d38ec90283b8e5ed06948c97fc8aa21a743a9605edaf34f4`.
- Authoritative red: `MIX_ENV=test mix test test/residency_schedule_web/http_protocol_security_test.exs` exited 2: **7 tests, 5 failures**, seed 868905. Three development/test/production config assertions show the disabled flag absent; runtime merge also lacks it. The real configured endpoint adapter listener responds to an HTTP/2 preface with a SETTINGS frame instead of rejecting the connection. Existing HTTP/1 login and LiveView WebSocket upgrade tests pass. No fixture/runtime failures. Local log: `/tmp/bandit-http2-red.log`.
- Reviewer requested a guard for every configured HTTP and HTTPS listener without introducing a new listener. Final accepted contract SHA256: `ad6e609c6f1fefd21f3b060d35a836535a9226b5a80ec3ab8a12a2d6d34acc30`.
- Refreshed authoritative red before implementation: same command exited 2, **7 tests, 5 failures**. Production base configuration lacks an HTTP entry before runtime configuration; development/test/runtime disabled flag assertions fail, and the actual listener still returns HTTP/2 SETTINGS. HTTP/1 and WebSocket tests pass. Local log: `/tmp/bandit-http2-red-final.log`. Reviewer accepted the final contract before authorizing implementation.

## Final verification

- Source owner force-formatted owned `config/config.exs`. Runner made no source/test edits.
- Focused command: `MIX_ENV=test mix test test/residency_schedule_web/http_protocol_security_test.exs test/residency_schedule_web/live/resident_adjacent_rotations_test.exs`: **pass**, 17 tests, 0 failures, seed 578695. Real configured endpoint rejects the HTTP/2 preface; HTTP/1 login and LiveView WebSocket upgrade still pass. Rotation contract remains green. Local log: `/tmp/bandit-http2-green.log`.
- `MIX_ENV=test mix format --check-formatted`: **pass**.
- `MIX_ENV=test mix compile --warnings-as-errors`: **pass**.
- `MIX_ENV=test mix deps.unlock --check-unused`: **pass**.
- `MIX_ENV=test mix credo`: **pass**, 57 checks on 316 files, no issues.
- `git diff --check`: **pass**.
- Both accepted contract hashes are unchanged after source implementation and formatting.
- Full suite `MIX_ENV=test mix test`: **pass**, exit 0, 216 doctests, 1703 tests, 0 failures in 70.5 seconds. Local log: `/tmp/bandit-http2-full-test.log`. Existing negative `Date.range/2` warnings and test-local `:eprof` warnings remain; no test failures.
- JavaScript/assets were not rerun: no asset source changed. No push or deployment performed by the runner.
- Fresh dependency metadata/audit results are recorded by the reviewer independently. Raw audit exit 1 for the named Bandit advisory is preserved; the explicit temporary exception and a fresh live check immediately before each commit remain required. Functional green does not establish a patched dependency or deployed mitigation.
