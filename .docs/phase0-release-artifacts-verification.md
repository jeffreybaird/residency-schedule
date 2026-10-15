# Phase 0 release artifact verification

## Scope and environment

Implementation follow-up on branch `codex/phase0-release-artifacts`. Design reference: [Phase 0 deployment documentation, PR #77](https://github.com/jeffreybaird/residency-schedule/pull/77). The design is in a separate documentation PR; this verification does not depend on an absent relative Phase 0 file.

Runner edits no source or tests and performs no Git mutations, commits, pushes, live-host access, or deployment. Deployment regression tests use Python standard-library unittest, isolated temporary files, real local filesystem locks, and stub service/network executables. No real service restart or network deployment is authorized by these checks.

Elixir runtime activation remains `source /workspace/.setup/activate.sh`, with local PostgreSQL and additional network permission for Mix PubSub/protocol mitigation tests. Existing Mix task help was read earlier in the session.

## Test contract

- Initial contract: `test/deploy/release_artifacts_test.py`, SHA256 `3bc03d8e4adf1b9779af9122322e0b36246201f1963486c12fa666ccfda7d0ca`.
- Authoritative initial red: `python3 -m unittest discover -s test/deploy -p '*_test.py'` exited 1: **15 tests, 23 assertion failures including subtests, 0 errors**, 0.026 seconds. Expected missing `package_release.sh` / `promote_release.sh` and absent build workflow job failures. Script behavior fixtures are not reached until implementation. Local log: `/tmp/phase0-red.log`.
- Writer confirmed environment-only cookie and missing-both branches already included in this contract; the originally reported 16 count was a reporting typo. Reviewer accepted the final 15-test contract at the recorded hash before source implementation.
- Parent requested stronger exact-content artifact identity and closure of the deployment lock descriptor in release eval/seed children. Expanded contract SHA256: `99eaf9d0ebc175a71c07e68bde52111025c69ea0fd569d39cfa48d26eef28815`, **18 tests**. Artifact identity combines commit SHA and archive SHA256; runtime `RELEASE_ID` remains the commit and `ARTIFACT_ID` selects exact retained content.
- Expanded authoritative red: same unittest command exited 1, **18 tests, 4 failures and 3 errors** in 7.583 seconds. Expected missing content-addressed retained paths / `ARTIFACT_ID`, same-commit rebuild collision, failed-candidate retention assertions, and inherited FD 9 were demonstrated. File-not-found errors are for the newly required identity paths, not unrelated fixture errors. Local log: `/tmp/phase0-content-red.log`.
- Reviewer formally accepted the expanded contract before source corrections. Renewed authoritative green: same command exited 0, **18 tests in 7.886 seconds**, including exact-content identity, immutable retention, and closed child FD 9. Local log: `/tmp/phase0-content-green.log`. Final accepted test hash remains `99eaf9d0ebc175a71c07e68bde52111025c69ea0fd569d39cfa48d26eef28815`.

## Verification gates

- Authoritative green: `python3 -m unittest discover -s test/deploy -p '*_test.py'` exited 0, **15 tests in 5.778 seconds**. Local log: `/tmp/phase0-green-first.log`. Actual temporary-filesystem, FIFO synchronization, real `flock`, rollback failures, archive rejection, cookie handling, and workflow assertions all execute with stubbed external effects.
- `bash -n deploy/package_release.sh deploy/promote_release.sh`: **pass**.
- `python3 -m py_compile deploy/release_artifact.py test/deploy/release_artifacts_test.py`: **pass**.
- Both changed workflows parse with PyYAML 6.0.3 using `BaseLoader` (preserves GitHub's `on` key). Each job has a steps list. Every `run` and SSH `with.script` value passes `bash -n`: CI 1 job / 4 shell snippets; deployment 3 jobs / 10 shell snippets. The accepted Python workflow regression also passes. `shellcheck` and `actionlint` are unavailable; this is syntax/structure validation, not an actionlint substitute or a live GitHub Actions run. No new tooling dependencies were installed.
- `MIX_ENV=test mix format --check-formatted`, `mix compile --warnings-as-errors`, `mix deps.unlock --check-unused`, and `mix credo`: **pass** (Credo 57 checks on 317 files, no issues).
- `MIX_ENV=test mix test test/residency_schedule_web/http_protocol_security_test.exs`: **pass**, 7 tests, 0 failures, seed 661258. Local log: `/tmp/phase0-protocol-mitigation.log`. Frozen protocol contract remains SHA256 `ad6e609c6f1fefd21f3b060d35a836535a9226b5a80ec3ab8a12a2d6d34acc30`.
- Final full application suite after the expanded deployment contract passed: `MIX_ENV=test mix test` exited 0, **216 doctests, 1706 tests, 0 failures** in 65.7 seconds. Local log: `/tmp/phase0-full-test.log`. Existing negative `Date.range/2` and test-local `:eprof` warnings remain; no new application warning was introduced. Application source/tests are unchanged by this deployment-only implementation.
- `git diff --check`: **pass** on the initial implementation. Expanded accepted deployment contract will be hash-checked after implementation.
- Final post-suite hashes confirm the expanded 18-test deployment contract and frozen protocol mitigation contract unchanged. Final Bash/Python syntax, workflow structure/embedded shell syntax, and `git diff --check` pass after the content-address correction.

## Actual Mix release and package smoke test

- Read `mix help release` before running `MIX_ENV=prod mix release --path /tmp/phase0-real-release`: **pass**, release 0.1.0 assembled from actual project/dependency code. No production runtime credentials were provided; no release start command was run. Build log: `/tmp/phase0-real-release-build.log`.
- Stamped only the generated release's `lib/residency_schedule-0.1.0/priv/deploy_sha` with the local base commit `79e35115db5149746b5e47d0f6345542e755c361` to model CI's deployment marker without editing tracked source. This test identity is a local build identity, not a claim that uncommitted deployment changes exist in that commit.
- Ran `bash deploy/package_release.sh /tmp/phase0-real-release /tmp/phase0-real-artifact 79e35115db5149746b5e47d0f6345542e755c361`: **pass**. The actual assembled release contained a generated private `releases/COOKIE`; the resulting tar excludes that file and its contents.
- Verified the checksum with `sha256sum --check`, tar `RELEASE_ID`, and real application `priv/deploy_sha`: **pass**. Package contains **2494 members**, **32,405,441 bytes**, no symlinks/hardlinks, no `.env` paths, and no generated cookie bytes in any regular file. Deployment marker location is `lib/residency_schedule-0.1.0/priv/deploy_sha`.
- Ran the real helper `stage` operation into `/tmp/phase0-real-staged` with retention under `/tmp/phase0-real-retained`: **pass**, executable and identity retained, cookie absent. No service command, live host, application process, or migration was invoked by this smoke test.
- After the exact-content identity correction, reran packaging validation, then real `stage` into `/tmp/phase0-real-staged-content`, retention under `/tmp/phase0-real-retained-content`, and `snapshot` validation of the existing retained artifact: **pass**. `RELEASE_ID` remains the commit; `ARTIFACT_ID` is `79e35115db5149746b5e47d0f6345542e755c361-2f21da7be4254a76a860d6f1245136a3889af223ee5bcc4dba0883a60378b46b`. Retained basename and bytes match this digest, its checksum passes, and the staged tree has no cookie. The actual application release was not rebuilt because no application/build source changed.

Current dependency advisory review belongs to the reviewer; fresh per-commit live package check belongs to the parent under the named temporary Bandit exception. Raw audit status must remain visible. Passing local verification does not assert deployment compatibility with uninspected host state or a completed live deployment.
