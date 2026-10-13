# Schedule render updates security review — October 13, 2026

The independent reviewer refreshed advisory data for this PR.

- `mix hex.audit`: exit 0, no retired packages. This checks retirement, not vulnerabilities.
- Downloaded the current public [bulk OSV Hex database](https://osv-vulnerabilities.storage.googleapis.com/Hex/all.zip). All **377 records** were byte-identical to the previously evaluated database, and all **51 direct/transitive locked Hex versions** were unchanged. The explicit-version and semantic-range comparison remains **zero matching advisories, zero unsupported applicable ranges**. No dependency metadata was uploaded. Evidence: `/tmp/schedule-render-updates-hex.zip` and `/tmp/schedule-render-updates-hex-result.json`.
- Refreshed the [official OTP advisory API](https://api.github.com/repos/erlang/otp/security-advisories?per_page=100): **70 records**, unchanged. Evidence: `/tmp/schedule-render-updates-otp.json`.
- `elixir -e` rechecked the local runtime: OTP **29.0.1**, ERTS **17.0.1**, ssl 11.7.1, ssh 6.0, inets 9.7, snmp 5.20.4, eldap 1.3, asn1 5.5, public_key 1.21.1, megaco 4.9, stdlib 8.0, erl_interface 5.8 and ftp 1.2.5.

The **40 pre-existing local OTP findings remain**. Exact advisory identifiers,
installed/affected versions, patched component versions and exposure conditions
are in the [runtime advisory table](qgenda-oct12-security-review.md#pre-existing-host-runtime-findings),
verified against the refreshed official data and executable versions. Patched
OTP releases covering them are **29.1.1**, **28.5.0.7**, or **27.3.4.18**.
Repository tooling, CI and deployment already pin **28.5.0.7**; the shared local
Homebrew runtime is separate and unchanged. Production's actual runtime remains
unverified. Outgoing TLS may reach affected SSL/public-key/ASN.1 code; exact
exploit prerequisites and production exposure remain uncertain. Application
SSH/SFTP, SNMP, LDAP, Megaco and FTP use was not observed.

No compatible dependency upgrade is indicated. There is no npm manifest or
lockfile in `assets`. Vendored/Git assets, operating-system packages, undisclosed
issues and the actual production runtime are outside this Hex scan. This review
does not claim comprehensive application security.

## Source and test review

The source change only moves the fixed column width into mount assigns and
precomputes the existing resident grouping when its inputs change. It adds no
endpoint, external export, database query, dependency or authorization change.
Per-user filter and viewed-year state stay on each socket. Modal visibility still
checks those current values, and deletion reloads the prepared data and grouping.
The shared-cache payload is unchanged.

The reviewer accepted real LiveView diff tests before implementation. Tests keep
fingerprints and component state, clear socket changes between renders, merge
diffs like the client, and verify reconstructed HTML. They require unchanged
rows to be absent from modal/navigation diffs while checking correct cohort
filtering, focus tokens, column width and deletion through the empty state.
The independent source review confirmed unchanged markup, IDs and grouping rules;
only their assign dependencies changed. This does not reduce initial full-grid
rendering or HTML size.

Audit review found one ambiguous reviewer-role flag while a read-only `rg` and
`shasum` command overlapped the spec writer's diff-harness correction. The writer
reported that edit independently; it added the framework's private-event render
and temporary-state clearing without weakening assertions. The reviewer inspected
and accepted it. The command itself made no source or test edits.
