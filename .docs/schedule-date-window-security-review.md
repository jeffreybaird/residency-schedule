# Schedule date window security review — October 13, 2026

Fresh advisory checks for this change:

- `mix hex.audit`: exit 0, no retired or security advisory packages. Hex warned that its authentication session expired and continued anonymously; private-resource checks remain unavailable. The first sandboxed attempt could not open Mix's local TCP socket; the authorized retry succeeded.
- Refreshed the [public Hex OSV database](https://osv-vulnerabilities.storage.googleapis.com/Hex/all.zip): all 377 records match the previously evaluated explicit-version and semantic-range scan, and all 51 locked direct/transitive versions remain unchanged. Zero matching advisories and zero unsupported applicable ranges. Evidence: `/tmp/schedule-date-window-hex.zip` and `/tmp/render-diagnostics-hex-result.json`.
- Refreshed the [official OTP advisory API](https://api.github.com/repos/erlang/otp/security-advisories?per_page=100): all 70 records are unchanged. Evidence: `/tmp/schedule-date-window-otp.json`.
- Rechecked the installed runtime files: OTP 29.0.1, ERTS 17.0.1; ssl 11.7.1, ssh 6.0, inets 9.7, snmp 5.20.4, eldap 1.3, asn1 5.5, public_key 1.21.1, megaco 4.9, stdlib 8.0, erl_interface 5.8, ftp 1.2.5.

The **40 pre-existing local OTP findings remain**. Exact identifiers, affected
and installed versions, patched component versions and exposure conditions are
listed in the [runtime advisory table](qgenda-oct12-security-review.md#pre-existing-host-runtime-findings),
verified against freshly retrieved official data. Patched complete releases are
29.1.1, 28.5.0.7 or 27.3.4.18. Repository tooling, CI and deployment pin 28.5.0.7;
the shared Homebrew runtime is unchanged. Actual production runtime is unverified.
Outgoing TLS may reach affected SSL/public-key/ASN.1 components; exploit
prerequisites and production exposure remain uncertain. Application SSH/SFTP,
SNMP, LDAP, Megaco and FTP use was not observed.

No compatible locked-dependency security upgrade is indicated. No npm manifest
or lockfile exists in assets. Vendored/Git assets, OS packages, undisclosed
issues and actual production runtime are outside the Hex comparison. This is
not a claim of comprehensive application security.

The independent source review confirms server-side window bounds and validation
of the first-visible index before academic-year lookup. Full cached records stay
server-side; rendered cell clipping preserves original detail tokens and dates.
The new event is fixed-name and telemetry adds only four numeric workload counts
and one fixed changed-assign flag. No slot indices, dates, payloads or resident
identifiers are added to exported attributes. The complete populated render
remains bounded at 39 attributes.

Review found and corrected modal close restoring the original range with the
wrong academic-year filter groups. A dedicated cross-year regression now covers
restoring both original groups and the opener. Client regressions cover bounded
request coalescing, stale acknowledgments after disconnect, and focus waiting
for the restored window.

New audit ownership warnings are marked ambiguous and occurred during read-only
inspection or test commands overlapping the responsible source/test owners.
The observed deltas match the reviewed owner changes and accepted test revisions;
there is no evidence of an unauthorized direct source/test edit.
