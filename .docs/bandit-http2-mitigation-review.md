# Bandit HTTP/2 mitigation independent review — October 15, 2026

The user authorized disabling HTTP/2 and a temporary, narrowly scoped exception for the disclosed Bandit advisory, with a mandatory patch check before every commit.

## Accepted contract and directive

Reviewer accepted `test/residency_schedule_web/http_protocol_security_test.exs`, SHA256 `ad6e609c6f1fefd21f3b060d35a836535a9226b5a80ec3ab8a12a2d6d34acc30`, before implementation. Seven tests check every configured HTTP/HTTPS listener's disabled HTTP/2 setting across development, test and production configuration, preservation through runtime port configuration, and a real configured Phoenix adapter listener. Actual wire checks require HTTP/2 preface rejection while HTTP/1 login requests and LiveView WebSocket upgrade continue working. No HTTPS listener is introduced. Runner refreshed authoritative red: exit 2, seven tests, five expected failures; HTTP/1 and WebSocket checks pass before mitigation. Evidence: `/tmp/bandit-http2-red-final.log`.

Independently reviewed [the exception](bandit-http2-audit-exception.md) and its project-guidance directive. Accepted: exact named advisory only; HTTP/2 disabled on every configured listener; genuine protocol regression checks; raw audit and actual nonzero status retained; fresh live patch metadata required immediately before every commit; stale/unavailable/ambiguous metadata and unrelated findings block; expiration on a published fix followed by upgrade, retesting and directive removal. No generated workflow or hook changes are authorized or needed. The exception permits the specified disclosed finding conditionally; it does not call the package fixed or the audit clean.

## Current advisory evidence

Fresh standalone `source /workspace/.setup/activate.sh` followed by `mix hex.audit` exits **1**, with one finding: **Bandit 1.12.5, EEF-CVE-2026-105659 / CVE-2026-105659 / GHSA-69m6-wcv4-rwcf**, HIGH. HTTP/2 blocked-send deadlines reset on WINDOW_UPDATE traffic, permitting prolonged stream-process retention. Raw evidence: `/tmp/bandit-http2-override-audit.log`.

Live Hex package/release APIs confirm installed/latest stable/latest **1.12.5**, affected range **>=1.4.0**, and **no published fixed release**. The advisory references fix commit `d88b21953c65061f21136ea76a89a4f95a2ac7a1`; no git pin or advisory suppression was introduced. Evidence: `/tmp/bandit-http2-override-package.json` and `/tmp/bandit-http2-override-release.json`. This review's check does not replace the required fresh check immediately before each actual commit.

The earlier [security review](consecutive-rotation-merge-security-review.md) records the cloud OTP component versions, previously documented separate-host runtime advisories and exposure uncertainty. Direct OSV, OTP advisory API and CNA detail feeds remain unavailable through the proxy; Hex metadata is accessible. Production protocol behavior and deployment remain unverified.

## Final source review

Independently reviewed the two added lines in `config/config.exs`: a dated-advisory comment and `http: [http_2_options: [enabled: false]]` on the base endpoint. `Bandit.PhoenixAdapter` passes options nested under `:http` to Bandit, whose initial protocol handler enforces the disabled setting. Environment/runtime keyword merging preserves the option; no HTTPS listener, dependency pin, advisory-ignore setting, or generated workflow/hook change was added. No actionable implementation defect was established.

The accepted protocol hash above and rotation contract hash `ca0f193a1cbbcbad4040666e58ec74bfd2457d7ed9df345f2b8adf55d6d6fb0a` remain unchanged after implementation/formatting. Runner focused protocol/rotation verification passes 17 tests. Full-suite output reports 216 doctests and 1,703 tests, zero failures; authoritative exit status and commands are recorded in [verification](bandit-http2-mitigation-verification.md). Global formatting, warnings-as-errors compilation, unused dependency checking, Credo and diff whitespace checks pass.

The Bash audit remains at its baseline 282 entries / 99 ambiguous violation flags, no exclusive flags and no new task records. Historical entries do not prove current cloud hook activation. Role communications, unchanged accepted tests and final diff inspection support ownership; no unowned source/test edit was established.

**Functional mitigation and exception directive accepted.** Commit eligibility is conditional on the exception's complete requirements, including another fresh live patch/advisory check immediately before each actual commit. The raw audit remains nonzero for the exact disclosed Bandit advisory; no published patched release is currently available. Any unrelated finding, unavailable/stale metadata, published fixed release, or listener serving HTTP/2 invalidates that eligibility. This review does not authorize deployment or claim that existing deployed listeners have changed.
