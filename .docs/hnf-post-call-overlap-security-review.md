# HNF/Post Call overlap security review — October 13, 2026

Independent fresh advisory checks:

- `mix hex.audit`: exit 0, “No retired or security advisory packages found.” Initial sandbox execution could not open Mix's local PubSub socket (`:eperm`); the audit succeeded with native escalation. Hex warned that authentication expired and continued anonymously. Public package advisory checks succeeded; private-resource checks are unavailable.
- Retrieved the [official OTP security advisory API](https://api.github.com/repos/erlang/otp/security-advisories?per_page=100) using Python `urllib.request.urlopen`: 70 records, latest publication September 22, 2026, with no new advisory identifiers relative to the earlier same-day snapshot. Evidence: `/tmp/hnf-overlap-otp-advisories.json`.
- `elixir --version` reports OTP 29 / ERTS 17.0.1, corresponding to OTP 29.0.1. `elixir -e` using `Application.spec/2` confirms unchanged installed components: ssl 11.7.1, ssh 6.0, inets 9.7, snmp 5.20.4, eldap 1.3, asn1 5.5, public_key 1.21.1, megaco 4.9, stdlib 8.0, erl_interface 5.8, ftp 1.2.5.

The **40 pre-existing local OTP runtime findings remain**. Each advisory identifier, affected dependency and installed version, affected range, patched component versions, patched runtime versions, and exposure uncertainty is listed in the [runtime advisory table](qgenda-oct12-security-review.md#pre-existing-host-runtime-findings). The installed versions and fresh official advisory feed agree with that table. Complete patched runtime options are **29.1.1**, **28.5.0.7**, or **27.3.4.18**. See the [official OTP 29.1.1 release](https://www.erlang.org/patches/OTP-29.1.1).

In particular, critical TLS client authentication bypass **GHSA-rgxr-4g4w-j875 / CVE-2026-89422** affects installed ssl 11.7.1; patched ssl versions are 11.7.7, 11.6.0.6, and 11.2.12.13. Outgoing HTTPS clients can reach SSL/public-key/ASN.1 code; endpoint/configuration prerequisites and production exposure are unverified. App SSH/SFTP, SNMP, LDAP, Megaco and FTP use has not been observed. Other runtime findings and their individual uncertainty remain as documented in the table.

`.tool-versions`, CI, and deploy workflows already pin patched OTP **28.5.0.7**. Those pins do not replace the active shared host runtime. Actual production runtime is unverified. Host runtime replacement is separate from this overlap correction and has not been performed.

No compatible locked-dependency security upgrade is indicated by the current Hex audit. No npm manifest or lockfile exists in assets. Git/vendored assets, operating-system packages, undisclosed vulnerabilities, and actual production runtime are outside this package audit; the result is not a comprehensive security assessment.
