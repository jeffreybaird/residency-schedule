# Phase 0 release artifact verification

## Scope and runtime

Current implementation uses Bash wrappers, a Ruby standard-library artifact helper, and Ruby/Minitest deployment tests and stubs. The user requested removal of Python and approved Ruby. No Python runtime, Gemfile, or added gem dependency is required by the final implementation or verification.

Design reference: [Phase 0 deployment documentation, PR #77](https://github.com/jeffreybaird/residency-schedule/pull/77). Runner edits no source or tests and performs no Git mutation, live-host access, service restart, or deployment. Fixtures use synthetic data, temporary files, real local filesystem locks/FIFOs, and stub external commands.

Local activation: `source /workspace/.setup/activate.sh` followed by `source /workspace/.setup/activate-ruby.sh`. Runtime: Ruby 3.3.8, Minitest 5.25.4, Psych 5.1.2, with RubyGems archive and zlib support. CI selects the maintained Ruby `3.3` family. RuboCop, shellcheck, and actionlint are unavailable; no new lint dependencies were installed.

## Accepted contract and authoritative red/green

- Contract: `test/deploy/release_artifacts_test.rb`, SHA256 `2919f5a0a9251b7a94f73ace2191bd87f858f6808fef85a9f04d07973b72fcac`.
- Red before source port: `ruby test/deploy/release_artifacts_test.rb` exited 1: **22 runs, 4433 assertions, 3 failures, 0 errors, 0 skips**, 13.175 seconds, seed 34372. Expected failures demonstrated the absent Ruby helper/runtime guard, old workflow command, and acceptance of PAX/GNU metadata. Other behavioral fixtures passed. Log: `/tmp/phase0-ruby-red.log`.
- Reviewer accepted the contract after genuine red and before source porting.
- Green: same command exited 0: **22 runs, 4471 assertions, 0 failures, 0 errors, 0 skips**, 17.337 seconds, seed 525. Log: `/tmp/phase0-ruby-green-first.log`. Tests retain original artifact/privacy/checksum/rollback/real-lock/FD-closure behavior and add Ruby-only execution, malformed/truncated headers, and PAX/GNU metadata rejection.
- Final workflow-only check after selecting Ruby `3.3`: `ruby test/deploy/release_artifacts_test.rb --name /workflow/` exited 0: **1 run, 37 assertions**, seed 35470. Log: `/tmp/phase0-ruby-workflow-final.log`.
- Final post-suite accepted contract hash is unchanged. The removed earlier deployment test is superseded by the accepted Ruby contract.

## Current checks

- `ruby -c deploy/release_artifact.rb` and `ruby -c test/deploy/release_artifacts_test.rb`: **pass**.
- `bash -n deploy/package_release.sh deploy/promote_release.sh`: **pass**.
- Both changed workflows parse using Ruby/Psych; each job has a steps list. All `run` and SSH `with.script` values pass `bash -n`: CI **1 job / 4 shell snippets**, deployment **3 jobs / 10 shell snippets**. This checks syntax/structure; it is not an actionlint result or live Actions execution.
- `MIX_ENV=test mix format --check-formatted`, `MIX_ENV=test mix compile --warnings-as-errors`, `MIX_ENV=test mix deps.unlock --check-unused`, and `MIX_ENV=test mix credo`: **pass**. Credo ran 57 checks on 317 files with no issues. Log: `/tmp/phase0-ruby-credo.log`.
- Frozen protocol mitigation: `MIX_ENV=test mix test test/residency_schedule_web/http_protocol_security_test.exs` exited 0: **7 tests, 0 failures**, seed 114509. Log: `/tmp/bandit-1.13-protocol-final.log`. SHA256 remains `ad6e609c6f1fefd21f3b060d35a836535a9226b5a80ec3ab8a12a2d6d34acc30`.
- Final full application suite: `MIX_ENV=test mix test` exited 0: **216 doctests, 1706 tests, 0 failures**, 68.7 seconds, seed 199561. Log: `/tmp/phase0-ruby-full-test.log`. Existing negative `Date.range/2` and test-local `:eprof` warnings remain; no new application warning was introduced.
- Final `git diff --check`: **pass**. No asset source changed, so an additional asset build was not run for this port.

## Actual patched release and Ruby artifact smoke test

- Read `mix help release` before building. `MIX_ENV=prod mix release --path /tmp/phase0-ruby-patched-release`: **pass**. No production runtime credentials were provided and no release start command was run. Build log: `/tmp/phase0-ruby-patched-release-build.log`.
- The assembled tree contains `lib/bandit-1.13.0` and `lib/thousand_island-1.6.0`, confirming it uses the patched dependencies rather than the earlier retained release tree.
- Stamped only generated `lib/residency_schedule-0.1.0/priv/deploy_sha` with local base identity `64ba9bf3b7a8fcd818dd4825e8df0092cc5a57af` to model CI without editing tracked source. This identifies the local smoke fixture; it does not claim uncommitted changes exist in that commit.
- `bash deploy/package_release.sh /tmp/phase0-ruby-patched-release /tmp/phase0-ruby-patched-artifact 64ba9bf3b7a8fcd818dd4825e8df0092cc5a57af`: **pass** using the real Ruby helper and actual assembled Mix release. Ruby USTAR validation accepts the real release paths without PAX/GNU extensions.
- Verified archive checksum, `RELEASE_ID`, and real `lib/residency_schedule-0.1.0/priv/deploy_sha`: **pass**. Package contains **2494 members**, **32,556,585 bytes**, no links or `.env` paths, and neither the generated `releases/COOKIE` nor its bytes in any regular file.
- Real Ruby helper `stage` into `/tmp/phase0-ruby-patched-staged`, retention under `/tmp/phase0-ruby-patched-retained`, then `snapshot` exact-artifact verification: **pass**. `RELEASE_ID` remains the commit; `ARTIFACT_ID` is `64ba9bf3b7a8fcd818dd4825e8df0092cc5a57af-d1377052dfe4b73dcd3fc27ad4ba04c64c162670bd5ff145e9f422691d33c288`. Retained bytes and checksum match this digest, and the staged tree has no cookie. No application process or migration was started.

## Security and limits

Bandit 1.13.0 is published and fixes the prior HTTP/2 advisory plus the newly disclosed HTTP/1 authority advisory. The temporary audit exception has expired; it no longer authorizes a failing audit. See the independent [Bandit 1.13 upgrade verification](bandit-1.13-upgrade-verification.md) for advisory identifiers, current audit evidence, and separate security-change review. Reviewer has independently reported the upgraded audit exiting 0; parent must perform the fresh live patch/audit check immediately before committing. HTTP/2 remains disabled.

Local verification does not establish deployment compatibility with uninspected host state, a live deployment, or production service health. No live host was accessed.

## Historical evidence (superseded implementation)

The former implementation passed its 18-test contract and actual release smoke test before the user requested Ruby. Its historical logs are `/tmp/phase0-content-red.log`, `/tmp/phase0-content-green.log`, and `/tmp/phase0-full-test.log`. Those results do not substitute for the current Ruby and patched-dependency results above. The old temporary advisory exception is expired and grants no current commit authorization.
