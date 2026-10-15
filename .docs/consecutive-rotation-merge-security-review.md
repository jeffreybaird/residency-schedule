# Resident adjacent rotation merge security review — October 15, 2026

Independent reviewer checks in the managed cloud environment:

- `source /workspace/.setup/activate.sh` followed by `mix help hex.audit` and `mix hex.audit`, with network permissions: audit **exit 1**, one pre-existing HIGH advisory in Bandit 1.12.5. Hex 2.5.2 explicitly checks vulnerabilities and retirement. Initial sandbox execution failed to open Mix's local PubSub TCP socket (`:eperm`); the network-enabled retry succeeded in retrieving advisory data. No advisory suppression was added.
- **EEF-CVE-2026-105659 / CVE-2026-105659 / GHSA-69m6-wcv4-rwcf**, published October 14, 2026: HTTP/2 blocked-send deadlines reset on each WINDOW_UPDATE, permitting a trickle to pin stream processes indefinitely. Current Hex release metadata marks **Bandit >=1.4.0** affected, including installed **1.12.5**. **No patched package release is listed**; the package API's latest stable release is also 1.12.5. The advisory references upstream fix commit `d88b21953c65061f21136ea76a89a4f95a2ac7a1`. No compatible published upgrade is currently available. The finding was routed to the orchestrator for implementation-owner consideration; no dependency suppression or speculative dependency rewrite was applied.
- The application config uses `Bandit.PhoenixAdapter`. Exploitability requires attacker-controlled HTTP/2 flow-control traffic reaching the server while a response send is blocked. Actual production protocol negotiation, reverse proxy behavior, request authorization, and reachability were not verified. Authentication does not establish that the HTTP server's protocol handling is unreachable. Options include a future patched release, a separately tested HTTP/2 configuration mitigation if operationally appropriate, or review of the upstream patch.
- Fresh Hex API package and release metadata were retrieved successfully. Raw evidence: `/tmp/rotation-merge-bandit-package.json` and `/tmp/rotation-merge-bandit-release.json`. Sources: [Hex release advisory metadata](https://hex.pm/api/packages/bandit/releases/1.12.5), [maintainer advisory](https://github.com/mtrudel/bandit/security/advisories/GHSA-69m6-wcv4-rwcf).
- Independent OSV, Erlang/OTP GitHub advisory API, and CNA detail requests were unavailable: the proxy returned `403 Forbidden`. No old snapshot was treated as current. This limits independent verification of detailed remediation and new OTP advisories.
- The active cloud runtime reports **OTP 28 / ERTS 16.4.0.6**, with ssl 11.6.0.6, ssh 5.5.2.6, inets 9.6.2.3, snmp 5.20.2.2, eldap 1.2.16.1, asn1 5.4.3.1, public_key 1.20.3.5, megaco 4.8.3.2, stdlib 7.3.0.3, erl_interface 5.7.0.2, and ftp 1.2.4.1. These meet the patched OTP 28 component versions for the 40 previously documented macOS OTP 29.0.1 findings in the [complete prior advisory table](qgenda-oct12-security-review.md#pre-existing-host-runtime-findings). That table preserves each advisory identifier, affected installed version, patched versions, and exposure uncertainty. Those findings are not established against this cloud runtime; the old host and actual production runtime remain unverified.
- Decimal remains **3.1.2**, the previously applied patch for **CVE-2026-97853 / GHSA-6c27-994x-c52f**, affecting >=0.1.0,<3.1.2. That advisory concerns unbounded allocation when an attacker controls rounding places; the current Hex audit does not flag the installed version.

The Bash audit baseline is 282 entries, with 99 violation flags, all marked `attribution: ambiguous`; no exclusive flag. Latest baseline timestamp is `2026-10-13T23:58:36+00:00`. These pre-existing attribution flags do not establish unowned task edits. Final review must compare accepted test hashes and final role-owned changes; cloud hook activation is not established by installed configuration or historical entries.

Final source review repeated `source /workspace/.setup/activate.sh` followed by `mix hex.audit` with network permissions: **exit 1**, the same single Bandit advisory and no additional findings. The dependency manifests and lockfile are unchanged. The Bash audit remains at its baseline 282 entries / 99 ambiguous flags, with no new task records; cloud audit activation therefore remains unverified. Direct source/test ownership was checked using role communications, the accepted test hash, and independent final diff inspection.

The dependency audit remains failing because of the disclosed Bandit advisory with no published patched release. Functional test success must not be reported as a clean security audit. Vendored assets, operating-system packages, unpublished issues, and actual production runtime are outside this package audit.

## User-authorized mitigation follow-up — October 15, 2026

The user subsequently authorized disabling application HTTP/2 and a temporary
audit exception requiring a fresh patch check before every commit. The base
endpoint now disables HTTP/2; real listener tests verify rejected HTTP/2 prefaces
and preserved HTTP/1 responses and LiveView WebSocket upgrades. No listener or
deployment was added. The installed Bandit package remains vulnerable and the
raw audit continues to exit 1 for the named advisory. The reviewed
[exception](bandit-http2-audit-exception.md) permits that finding only while every
configured application listener disables HTTP/2, required checks pass, and fresh
live metadata confirms no published patched release immediately before each
commit. Other findings, failed/unavailable checks, or a published fix invalidate
the exception. See [mitigation review](bandit-http2-mitigation-review.md).
