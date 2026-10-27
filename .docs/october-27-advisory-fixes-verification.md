# October 27 dependency advisory fixes

Local synthetic verification for the separate advisory-fix PR. Starting source:
merged `main` commit `907426a`. No production deployment or configuration change
was performed.

## Scope and advisory red

Update Bandit **1.13.0 → 1.14.0** and plug_crypto **2.2.0 → 2.2.1** within the
existing dependency requirements. Preserve disabled HTTP/2 and application
behavior. No mapping, classification, schema or recovery-program work belongs in
this change.

Fresh baseline `mix hex.audit` exited **1** with the twelve findings below.
This is the security red condition; existing application compatibility tests
were expected to pass before and after updating dependencies.

| Installed package | Advisory | Exposure condition | Fixed version |
| --- | --- | --- | --- |
| Bandit 1.13.0 | EEF-CVE-2026-108529 | HTTP/2 blocked-stream quadratic work | 1.14.0 |
| Bandit 1.13.0 | EEF-CVE-2026-110499 | HTTP/2 HPACK encoder table growth | 1.14.0 |
| Bandit 1.13.0 | EEF-CVE-2026-109584 | HTTP/2 cookie allocation amplification | 1.14.0 |
| Bandit 1.13.0 | EEF-CVE-2026-111103 | HTTP/2 stream-error limit bypass | 1.14.0 |
| Bandit 1.13.0 | EEF-CVE-2026-108525 | HTTP/2 inbound flow-control enforcement | 1.14.0 |
| Bandit 1.13.0 | EEF-CVE-2026-115269 | HTTP/2 request-body timeout reset | 1.14.0 |
| Bandit 1.13.0 | EEF-CVE-2026-111101 | HTTP/1.1 tiny-chunk memory amplification | 1.14.0 |
| Bandit 1.13.0 | EEF-CVE-2026-113436 | Content-Length/Host-port bignum parsing | 1.14.0 |
| Bandit 1.13.0 | EEF-CVE-2026-114216 | Bare CR/LF chunk extensions and request smuggling | 1.14.0 |
| Bandit 1.13.0 | EEF-CVE-2026-110314 | WebSocket frames after server-initiated close | 1.14.0 |
| Bandit 1.13.0 | EEF-CVE-2026-114213 | WebSocket continuation-frame size-limit bypass | 1.14.0 |
| plug_crypto 2.2.0 | EEF-CVE-2026-105963 | Wrong-typed crypto arguments exposing secret key base in stack traces | 2.2.1 |

The existing source configuration disables Bandit's HTTP/2, limiting those
specific protocol paths; that setting does not mitigate HTTP/1.1 or WebSocket
findings. The crypto finding depends on wrong-typed calls and stack-trace
exposure. Live deployment configuration and exploitability were not inspected.
The complete advisory records are available from Hex and under
`https://osv.dev/vulnerability/<advisory-id>`.

## Environment and accepted compatibility contract

The work used its own checkout, `deps` and `_build` directories under
`/workspace/residency-security-advisories`. Dependency/build directories were
copied rather than symlinked from the original checkout; the original planning
worktree was not modified. Initial lock SHA256:
`bb51b87fb5488f325608ea2c5ea3c773f384c67765de9dc317455fb863b03697`.

Runtime: Elixir 1.19.5, Erlang/OTP 28.5.0.7 and the existing local PostgreSQL
17.11 cluster. Mix and PostgreSQL used sandboxed additional network permission
for local sockets and the configured proxy. `MIX_TEST_PARTITION=advisories`
selected the separate synthetic `residency_schedule_testadvisories` database.

An initial focused-test attempt could not connect because the local cluster was
stopped; no tests ran. The runner started that existing synthetic cluster using
its existing loopback/socket settings, then reran the command successfully.
This setup failure is not application red evidence.

The test writer proposed existing protocol, auth, account and OAuth tests, and
the reviewer accepted that compatibility contract before the dependency edit.
No new feature or test that mirrors upstream implementation was added. The
frozen files and SHA256 values are:

| Test path | SHA256 |
| --- | --- |
| `test/residency_schedule_web/http_protocol_security_test.exs` | `ad6e609c6f1fefd21f3b060d35a836535a9226b5a80ec3ab8a12a2d6d34acc30` |
| `test/residency_schedule_web/controllers/auth_controller_test.exs` | `7186cf2ffe8620cf207217a226ef19a3dd2bc3aeb5952febd55e1365026c3a31` |
| `test/residency_schedule_web/user_auth_test.exs` | `8b2587b234aad292d3c34218a166f4324e742922437f9e7059c136322fcfb8ef` |
| `test/residency_schedule/oauth/client_test.exs` | `f5eac1ec4a65847a783c9220f8cb3815bb1a132eadafe652c366b6562c3e965e` |
| `test/residency_schedule/oauth/metadata_test.exs` | `cc672e9444d70249c0da39a3acb9ede43dc917ee41e86f76f55e1db9b9ded2f0` |
| `test/residency_schedule/oauth/oauth_test.exs` | `0dd28d7cbe048f7fe23419d68535306275c7fa094f8f4adea644a715f3eb17fa` |
| `test/residency_schedule/oauth/pkce_test.exs` | `45f6eea71965c1a7a223000f6ab6af3d03943aad4f613f4bf8e9f2c5f3e3acfd` |
| `test/residency_schedule/oauth/secret_test.exs` | `e53ec558d02b5767cef314d864ecd441a1fc5c895d13fb0fdff75bf3e80798e9` |
| `test/residency_schedule/accounts/accounts_test.exs` | `b7827404507e2e441860d1785da8a85a1841a4d1bd47dd729c0733cef8ff864d` |
| `test/residency_schedule/accounts/user_test.exs` | `2a7fd4416a422b5d14822976ff5b5af67042d5e095888318dc79bf0cc099f68b` |

Focused command, after sourcing `/workspace/.setup/activate.sh`:

```sh
MIX_TEST_PARTITION=advisories mix test test/residency_schedule_web/http_protocol_security_test.exs test/residency_schedule_web/controllers/auth_controller_test.exs test/residency_schedule_web/user_auth_test.exs test/residency_schedule/accounts test/residency_schedule/oauth
```

Baseline result: **38 doctests, 147 tests, zero failures**, exit zero, 1.7 seconds,
seed `627664`. All ten frozen test hashes matched before the dependency edit.

## Final verification

The source owner narrowly unlocked the two packages and fetched the resolved
versions, then formatted the owned dependency files and compiled with warnings
as errors. Exactly two lock entries changed: Bandit to 1.14.0 and plug_crypto to
2.2.1. No application, configuration, test or other dependency entry changed.
Final lock SHA256:
`0ca292f932368c6241c5b8208cad03873047b992a672f6c6db3a54cc3d49390d`.

The final focused command passed **38 doctests, 147 tests, zero failures**, exit
zero, 1.9 seconds, seed `497937`. The full suite then passed:

```sh
MIX_TEST_PARTITION=advisories mix test
```

Result: **220 doctests, 1,769 tests, zero failures**, exit zero, 85.2 seconds,
seed `441336`. Existing date-range reference warnings, profiler output and the
synthetic privacy sentinel appeared without causing failures.

Final checks passed after source-owner formatting:

- `MIX_ENV=test MIX_TEST_PARTITION=advisories mix compile --warnings-as-errors`.
- `mix format --check-formatted`.
- `mix credo --strict`: 332 files, no findings.
- `mix deps.unlock --check-unused`: no unused dependency lock entries.
- Fresh `mix hex.audit`: exit zero, “No retired or security advisory packages found.”
- All ten accepted test hashes remained unchanged.
- `git diff --check`.

These tests validate application compatibility and the existing protocol
configuration; they are not a claim to reproduce every upstream CVE. The audit
checks current Hex advisories, not comprehensive OS, Ruby, browser, runtime or
vendored-package security. No production environment was inspected or deployed.

The native Bash audit log is unchanged at 351 entries with 155 historical
violation-flag entries. Task-specific hook activation is unverified; source
ownership, the narrow final diff and the frozen test hashes are independently
reviewed instead of inferring that an installed hook ran.

## Independent acceptance

The reviewer accepted the existing compatibility-test contract before the
dependency edit and independently rechecked all ten frozen hashes afterward.
The final lock diff changes exactly the Bandit and plug_crypto entries; package
requirements and every other lock entry are unchanged. Application code, endpoint
configuration and tests are untouched, including the disabled HTTP/2 setting.

Independent no-cache reads of the Hex release API confirmed the twelve baseline
advisories and their affected bounds. Bandit 1.14.0 and plug_crypto 2.2.1 are
outside those affected ranges, are not retired and have no reported advisories
in the fetched metadata. Their public release checksums match the new lock
entries:

- Bandit 1.14.0: `2d07630e4bf77b55240881386f7629bcc2f87426a299860b2d31c4ad77a48746`.
- plug_crypto 2.2.1: `4417ccbd8f85e627321cd07d2ab9c4b621f1fd883b9905af241f9b4b780b94b6`.

The reviewer separately ran
`MIX_ENV=test MIX_TEST_PARTITION=advisories mix hex.audit`: exit zero, no retired
or security advisory Hex packages. The runner's final focused/full-suite and
static-check evidence above was inspected and accepted. No actionable source,
test or documentation finding remains for this narrow dependency update.

The exposure and coverage limits above remain explicit: source HTTP/2 mitigation
does not cover the HTTP/1.1 or WebSocket findings; crypto exposure depends on
wrong-typed calls and trace disclosure. Live configuration and exploitability
were not assessed, and this acceptance does not claim comprehensive runtime
security or a production deployment.
