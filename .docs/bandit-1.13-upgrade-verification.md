# Bandit 1.13 security upgrade — October 15, 2026

## Fresh advisory evidence

At **2026-10-15 21:42:06 UTC**, independent reviewer ran `source /workspace/.setup/activate.sh` followed by standalone `MIX_ENV=test mix hex.audit`: **exit 1**, installed Bandit **1.12.5**, with two findings:

| Advisory | Affected dependency/version | Fixed version | Exposure or uncertainty |
| --- | --- | --- | --- |
| EEF-CVE-2026-105659 / CVE-2026-105659 / GHSA-69m6-wcv4-rwcf — HIGH | Bandit 1.12.5; >=1.4.0,<1.13.0 | Bandit 1.13.0 | HTTP/2 WINDOW_UPDATE traffic can prolong blocked sends and retain stream processes. Application HTTP/2 is disabled; actual deployed configuration is unverified. |
| EEF-CVE-2026-105660 / CVE-2026-105660 / GHSA-v53v-9hvg-37jf — MEDIUM | Bandit 1.12.5; >=0.6.0,<1.13.0 | Bandit 1.13.0 | Unvalidated HTTP/1 request-target authority lets a client choose `conn.host` and `conn.port`. Exposure depends on proxy/request handling and consumers of those fields; actual production exposure is unverified. |

Live Hex package and release requests used `Cache-Control: no-cache`. Latest stable is **1.13.0**; its release metadata reports no advisories or retirement. The existing Bandit constraint `~>1.5` permits the upgrade without changing application APIs.

Sources: [installed release metadata](https://hex.pm/api/packages/bandit/releases/1.12.5), [fixed release metadata](https://hex.pm/api/packages/bandit/releases/1.13.0), [HTTP/2 advisory](https://osv.dev/vulnerability/EEF-CVE-2026-105659), [HTTP/1 advisory](https://osv.dev/vulnerability/EEF-CVE-2026-105660). Raw local evidence: `/tmp/phase0-ruby-port-audit.log`, `/tmp/phase0-ruby-port-bandit-package.json`, `/tmp/phase0-ruby-port-bandit-release.json`, `/tmp/phase0-ruby-port-bandit-patched.json`.

## Change and exception retirement

The source owner upgraded **Bandit 1.12.5 → 1.13.0** and its resolved dependency **Thousand Island 1.5.0 → 1.6.0**. Independent diff inspection confirms the lockfile change is limited to those two entries. No advisory suppression was added. The application's disabled HTTP/2 configuration remains in place.

Availability of the fixed release immediately expires the temporary HTTP/2-only audit exception. The active exception and project-guidance directive are retired; their old no-fix baseline is historical evidence, not authorization for further commits with either finding. Ordinary current dependency auditing remains required by the shared project workflow.

## Verification

Independent reviewer repeated standalone `MIX_ENV=test mix hex.audit` after the upgrade: **exit 0**, “No retired or security advisory packages found.” Raw local evidence: `/tmp/bandit-1.13-review-audit.log`. This is a current locked-package check, not a comprehensive runtime assessment.

Authoritative runner verification after the dependency upgrade:

- Protocol-security regressions: **seven tests, zero failures**, exit 0, seed 114509. HTTP/2 remains rejected; HTTP/1 login and LiveView WebSocket upgrade continue working. Evidence: `/tmp/bandit-1.13-protocol-final.log`.
- Full application suite: **216 doctests and 1,706 tests, zero failures**, exit 0 in 68.7 seconds, seed 199561. Evidence: `/tmp/phase0-ruby-full-test.log`.
- Formatting, warnings-as-errors compilation, unused dependency checking and Credo: pass; Credo checked 317 files with 57 checks. Existing Date/eprof test warnings are unchanged.
- Frozen protocol-test SHA256 remains `ad6e609c6f1fefd21f3b060d35a836535a9226b5a80ec3ab8a12a2d6d34acc30`.
- A newly assembled local release contains Bandit 1.13.0 and Thousand Island 1.6.0. No application service or production deployment was started.

Independent review accepts the compatible two-entry lockfile upgrade and removal of the active exception/directive. No remaining actionable finding was established by the current locked-package audit. This record does not claim deployment or that an installed production release has changed. A fresh security check before the actual commit remains the parent's responsibility.

The package audit does not cover operating-system packages, vendored code, unknown vulnerabilities or actual production runtime. Previously recorded separate-host OTP findings and component-specific patched versions remain documented in [the earlier security review](consecutive-rotation-merge-security-review.md); cloud component versions met those documented patches, while production runtime and independent advisory-feed completeness remain unverified.
