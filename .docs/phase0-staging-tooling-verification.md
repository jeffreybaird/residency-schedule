# Persistent staging tooling verification

October 16, 2026, on `codex/phase0-release-artifacts`.

This records the repository staging implementation pipeline. It does not establish
live staging persistence, recovery, host readiness or production approval.

## Accepted behavior and ownership

The orchestrator delegated tests to `workflow_spec_writer`, source changes to
`workflow_implementer`, authoritative checks to `workflow_runner` and independent
contract/final review to `workflow_reviewer`. The reviewer accepted the contracts
before implementation and renewed acceptance for marker propagation, the exact
candidate branch trigger, and a formatting-only test correction.

The workflow builds a candidate once, promotes those artifact bytes to staging,
then permits production/demo only after staging succeeds and only on a push to
`main`. The exact candidate branch also triggers staging before the dispatcher
exists on the default branch. Staging has a separate environment, service, port,
install directory and Erlang node. It keeps authentication, never runs demo seed,
and rejects outbound integration settings. Its runtime uses the Swoosh test sink.
The staging marker reaches systemd and release evaluation; inherited staging
markers cannot change production evaluation behavior. Existing managed prod/demo
environment file bytes retain their canonical format.

Accepted SHA-256 hashes, unchanged at final review:

| Test file | SHA-256 |
| --- | --- |
| `test/deploy/release_artifacts_test.rb` | `f4b2be3fa30cfbf19dc77b9ee888c30b6483114328f199d9fe6cf54e8b3e5768` |
| `test/residency_schedule/staging_runtime_test.exs` | `7b460a368e9046c23bfad144dbb79f87438663a1ca70802a7c163c7d8248c01a` |

## Authoritative red and green evidence

- Runtime red: `mix test test/residency_schedule/staging_runtime_test.exs`, seed
  246907, four tests/one failure: staging incorrectly required `RESEND_API_KEY`.
- Marker red: the focused inherited-marker test failed at the assertion that
  production/demo release children must clear `CONFIG_ENVIRONMENT=staging`.
- Trigger red: focused candidate workflow test, seed 17127, one test/two
  assertions/one failure: candidate branch missing from push triggers.
- Final green: `ruby test/deploy/release_artifacts_test.rb` in the cached official
  `ruby:3.3.12-slim-bookworm` image, seed 27596: **47 tests, 10,638 assertions,
  zero failures/errors/skips**. The container used real Linux `flock`, Ruby 3.3.12,
  a read-only repository mount and no network access.
- Final runtime green: `mix test test/residency_schedule/staging_runtime_test.exs`,
  seed 52454: **four tests, zero failures**. Read-only formatting checks passed
  after the test writer corrected trailing whitespace. Ruby syntax and Bash
  syntax checks passed. The source owner ran required source formatting.

Independent final review passed with no code findings. Mock fixture persistence
tests prove deployment tooling avoids seed/reset operations; they do not prove
real database persistence or a successful transport/systemd rehearsal.

## Security review

The runner synchronized locked dependencies without changing `mix.lock`, then
ran a fresh `mix hex.audit`: no retired or advisory packages reported. Installed
versions include Bandit 1.13.0 and Thousand Island 1.6.0.

Current primary Ruby advisories identified pre-existing
[CVE-2026-80212 and CVE-2026-80213](https://www.ruby-lang.org/en/news/2026/08/27/multiple-vulnerabilities-in-resolv/)
in bundled `resolv` 0.3.1. Patched versions include 0.3.2 and 0.7.2. The cached
test image contains 0.3.1; the local Ruby 3.3.12 installation also has patched
0.3.2 installed. The vulnerable path requires direct `Resolv`/`resolv-replace`
use with attacker-influenced DNS; no such call was found in the deployment
tooling, which uses `URI.parse`. This does not establish runtime-wide absence
of exposure. Operational host remediation/verification belongs in the rollout
record, and the cached test-image advisory remains explicit.

Installed Bundler 2.5.22 is outside the affected range below 2.2.33 for
[GHSA-fj7f-vq84-fh43](https://github.com/ruby/rubygems/security/advisories/GHSA-fj7f-vq84-fh43).
The repository has no Gemfile or JavaScript package manifest. A comprehensive
all-gem advisory audit was not performed; a clean Hex scan does not imply one.

## Remaining gates

Real isolated staging bootstrap, persistent synthetic fixture import, two
deployments, transport/systemd recovery and measured operational checks remain
separate evidence. Manual fixture tooling and later fixes require their own
accepted contracts and green review. Production merge/deployment remains subject
to the handoff's final concrete go/no-go gate.
