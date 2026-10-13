# Schedule cell index security review — October 13, 2026

Independent advisory data was refreshed for this separate PR after the cache PR.

- `mix hex.audit`: exit 0, no retired packages. This is a retirement check, not a vulnerability scan.
- Downloaded the current public [bulk OSV Hex database](https://osv-vulnerabilities.storage.googleapis.com/Hex/all.zip). All **377 advisory records** were byte-identical to the earlier locally evaluated cache-PR database; all **51 direct and transitive locked Hex versions** were also identical. The explicit-version and semantic-version-range comparison therefore remains **zero matches, zero unsupported applicable ranges**. No project dependency metadata was uploaded. Evidence: `/tmp/schedule-cell-index-hex.zip` and `/tmp/schedule-cell-index-hex-result.json`.
- Refreshed the [official OTP security advisory API](https://api.github.com/repos/erlang/otp/security-advisories?per_page=100): **70 records**, unchanged. Evidence: `/tmp/schedule-cell-index-otp.json`.
- Rechecked the local executable with `elixir -e`: OTP **29.0.1**, ERTS **17.0.1**; ssl 11.7.1, ssh 6.0, inets 9.7, snmp 5.20.4, eldap 1.3, asn1 5.5, public_key 1.21.1, megaco 4.9, stdlib 8.0, erl_interface 5.8 and ftp 1.2.5 remain unchanged.

The **40 pre-existing local OTP findings remain**. Their exact identifiers,
installed/affected versions, patched component versions and exposure conditions
are in the [runtime advisory table](qgenda-oct12-security-review.md#pre-existing-host-runtime-findings),
reverified against the current official data and executable versions. Patched
OTP options covering the findings are **29.1.1**, **28.5.0.7**, or **27.3.4.18**.
Repository `.tool-versions`, CI and deployment already pin **28.5.0.7**;
the shared Homebrew runtime is separate and unchanged. Actual production runtime
remains unverified. Outgoing TLS can reach affected SSL/public-key/ASN.1 code;
exploit prerequisites and production exposure remain uncertain. Application use
of SSH/SFTP, SNMP, LDAP, Megaco and FTP was not observed.

No compatible locked-dependency update is indicated. There is no npm manifest or
lockfile in `assets`. Git/vendored assets, operating-system packages, undisclosed
issues and the actual production runtime are outside the Hex scan. This report
does not claim comprehensive application security.

## Implementation review

The source change is limited to in-memory rotation lookup during schedule cell
construction. It adds no network endpoint, database query, telemetry attribute,
dependency, authorization change or shared-cache payload. Rotation boundaries
and requested slot dates are indexed without expanding intervals into every
calendar day. Active rotations retain their original list ordinal, preserving
stable ordering and duplicate entries. Slot ordering, grouped-cell identity and
detail-token annotation remain unchanged.

The reviewer independently compared the frozen reference with the original
scan/filter/sort implementation, accepted exact-output regression tests before
implementation, and reviewed the sweep's inclusive boundaries, invalid-interval
handling, gaps, schedule partitions and legacy lookup precedence. The benchmark
asserts exact complete annotated-cell equality for each measured run. Process
reductions provide the deterministic performance regression; dense overlapping
results still require proportional enumeration.

Accepted test/reference hashes remained unchanged during initial source review.
The new audit entries were role-owned spec-writer formatting operations with no
ownership violations. Final test and benchmark evidence is recorded separately.
