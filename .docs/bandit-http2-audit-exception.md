# Resolved Bandit audit exception

The temporary exception authorized on October 15, 2026 is **expired and removed**.
Bandit 1.13.0 is now published and fixes both:

- **CVE-2026-105659 / GHSA-69m6-wcv4-rwcf / EEF-CVE-2026-105659**:
  HTTP/2 blocked-send deadlines could reset on WINDOW_UPDATE traffic; affected
  versions are `>= 1.4.0, < 1.13.0`.
- **CVE-2026-105660 / GHSA-v53v-9hvg-37jf / EEF-CVE-2026-105660**:
  HTTP/1 request-target authority could override the host/port selected for the
  connection; affected versions are `>= 0.6.0, < 1.13.0`.

The lockfile upgrades Bandit from 1.12.5 to 1.13.0 and its required Thousand
Island dependency from 1.5.0 to 1.6.0. HTTP/2 remains disabled pending a separate
tested decision. See [upgrade verification](bandit-1.13-upgrade-verification.md)
for current advisory evidence and validation.

This file preserves historical links from earlier reviews. It grants **no audit
waiver**. Run current security checks under the shared workflow; unresolved
findings, unavailable checks or stale metadata cannot qualify for the former
exception. The earlier no-patch observations remain historical evidence only.
