# OTel Hub integration verification

## Scope and privacy boundary

Residency Schedule exports logs, metrics, and traces through `otlp_shipper` only
when production runtime configuration explicitly enables it. The service name is
`residency-schedule`. HTTPS endpoint and source-scoped bearer token are required.
Development and test runtime configuration leave export disabled.

The exporter produces fixed HTTP completion log messages and request summary
spans, plus tagless endpoint, database timing, and VM metrics. HTTP method is
allowlisted; invalid methods become `_OTHER`. Response status is bounded. Raw
application logs, URLs, headers, SQL, resident information, and chat content are
excluded. Spans do not represent a distributed internal call tree. Deployment
administrators must keep additional `OTEL_RESOURCE_ATTRIBUTES` nonsensitive.

## Accepted test contract

The spec writer owns the four `observability*_test.exs` files. Independent review
accepted the final contract before implementation. The runner demonstrated red:

```sh
MIX_ENV=test mix test test/residency_schedule/observability_test.exs test/residency_schedule/observability_runtime_test.exs test/residency_schedule/observability_transport_test.exs
```

Result: 10 tests, 9 expected failures, exit status 2. The implementation module and
enabled runtime configuration were absent. Runner log:
`/private/tmp/residency-otel-red-final.log`.

Accepted SHA-256 hashes:

| Test | SHA-256 |
| --- | --- |
| `observability_doctest_test.exs` | `e210de8cc59365873f1b36413d10baac34f18de0300b15fb23d2ad181270c6b5` |
| `observability_runtime_test.exs` | `414e747e0edb4010455489b26399b1361546296a6470e36034eb5e90e3766e2c` |
| `observability_test.exs` | `dd3d89a13e3dbecf5f55bc4d0531f33c2105dc4b37709f6ac61752e69a72ffe5` |
| `observability_transport_test.exs` | `85a96618ed25b077fe7aa4ed33b0ceb3260c6fec3569419815f47f8b918d2aab` |

Transport tests decode actual localhost OTLP protobuf requests for all three
signals, verify authorization and resource identity, and search for synthetic
sensitive sentinels. Lifecycle tests check handler cleanup and single emission
after restart. A rejected export followed by successful export checks collector
failure recovery without taking down request producers.

Review identified an additional crash-recovery bug: an untrappable process kill
skips `terminate/2`, leaving a stale telemetry handler. The spec writer added a
regression and the reviewer renewed acceptance of the strengthened contract above.
The runner demonstrated red with
`MIX_ENV=test mix test test/residency_schedule/observability_transport_test.exs:7`:
1 test, 1 failure, exit status 2; the child remained `:restarting`. Log:
`/private/tmp/residency-otel-recovery-red.log`. Only then was the lifecycle fix
authorized. Additional tests exercise public doctests, invalid durations, and
header-delimiter token rejection.

## Security advisory review

Independent review downloaded the current public GitHub reviewed Erlang ecosystem advisory
catalog and compared its 121 entries locally against the original 47 locked Hex
packages. No installed vulnerable ranges matched. `mix hex.audit` also found no
retired dependencies; that command alone is not a vulnerability audit.
Git-sourced Heroicons and unversioned vendored assets are outside that Hex package
comparison; no claim of a complete vulnerability scan is made for those assets.

After dependency resolution, review repeated the comparison against all 51 locked
Hex packages with no matching affected ranges and reran `mix hex.audit` cleanly.
The published shipper version available at integration time is 0.2.1; local sibling
documentation describes an unpublished 0.2.2. This application uses published
`otlp_shipper ~> 0.2.1` with an explicit Mint minimum of 1.10.2 (resolved 1.11.0),
plus the shipper-verified SDK 1.7.0 / API 1.5.0 pair.

The application owns a named SDK provider, initializes the SDK's process-global
span limits explicitly, and supervises the SDK's shared span storage before its
provider. This uses pinned SDK 1.7.0 interfaces without starting a default global
provider. Adding other instrumentation or upgrading the SDK must revisit this
ownership and validate the provider startup, shared storage, and shared limits.

An OSV batch query was rejected by automatic approval review because it would
disclose dependency names and versions externally. The public catalog download
provided a permitted alternative without uploading the dependency inventory.

Local verification uses Elixir 1.19.5 / OTP 29.0.1. That installed OTP runtime has
the pre-existing advisories recorded in [the runtime security review](qgenda-security-review.md).
Current OTP advisory catalog review confirmed those findings remain applicable.
The integration requires Elixir 1.19 / OTP 28 or newer, and CI is upgraded to the
patched OTP 28.5.0.7 release. OTP 29 deployments require at least 29.1.1. These
versions address, among other findings, TLS authentication bypass
`GHSA-rgxr-4g4w-j875` and ASN.1 `GHSA-qghx-23m5-r55m`. The host runtime itself is
not changed by this repository patch.

## Final verification

The runner recorded these final green checks, all exit status 0:

| Check | Result |
| --- | --- |
| `mix format --check-formatted` | Passed after owners ran `mix format --force` on their paths |
| `MIX_ENV=test mix compile --warnings-as-errors` | Passed |
| `MIX_ENV=test mix test` | 193 doctests, 1,429 tests, zero failures |
| Focused four observability files | 6 doctests, 13 tests, zero failures |
| `MIX_ENV=test mix credo --strict` | 267 files, 2,179 modules/functions, no issues |
| `node --test test/assets/*.test.js` | 24 tests passed |
| `MIX_ENV=prod mix release --overwrite` | Release assembled |
| Production release smoke | Disabled: SDK packaged, global SDK stopped, exporter absent. Enabled: actual logs, metrics, traces delivered to loopback; global SDK remained stopped |

An alias-only Credo correction was made by the spec writer, reviewed as preserving
the accepted assertions, and reverified. The accepted hash table above includes
that correction. All other accepted hashes remained unchanged. The first JS
browser test attempt hit sandbox restrictions; the authorized rerun passed.

Evidence logs are `/private/tmp/residency-otel-{full-green,focused-green,credo,js-green,release-build,release-smoke}.log`.
Independent review accepted the implementation, deployment wiring, privacy
boundary, advisory results, and final diff. Audit-log review found no exclusive
role violation; violation-bearing entries were marked ambiguous because tools
overlapped. Existing unrelated work was preserved.

Production source registration, credentials, and delivery verification remain
separate operational steps; local test delivery does not establish production
collector delivery. No production activation or deployment is part of this
repository verification.

## Follow-up: pull-request CI toolchain

The parent review found that the separate `.github/workflows/ci.yml` still pinned
Elixir 1.18 / OTP 27 after the deploy workflow had been updated. The initial review
missed this file; those versions cannot build the new Elixir 1.19 dependencies.

The spec writer added `ci_runtime_compatibility_test.exs` to compare both workflow
pins with `.tool-versions` and the project's Elixir requirement. Independent review
accepted SHA-256 `203953c45ad40692198ee920a1cd764b6e908b4c93314148be3b6102052f21a7`.
The runner demonstrated red with
`MIX_ENV=test mix test test/residency_schedule/ci_runtime_compatibility_test.exs`:
1 test, 1 failure, exit status 2 (`/private/tmp/residency-otel-ci-red.log`). The
implementer was then authorized to align the two CI pins with Elixir 1.19.5 / OTP
28.5.0.7. Dependency locks and advisory results are unchanged.

After the correction, the runner recorded green: 1 test, zero failures; read-only
format check passed; strict Credo checked 268 files and 2,181 modules/functions
with no issues. The accepted test hash was unchanged. Evidence:
`/private/tmp/residency-otel-ci-green.log`. The earlier full suite and release
smoke remain applicable; this follow-up changes only CI version pins and adds the
compatibility regression.
