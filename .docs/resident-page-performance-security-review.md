# Resident page performance security review — October 13, 2026

Fresh independent advisory checks:

- `mix hex.audit`: exit 0, no retired or security advisory packages. Hex continued anonymously after warning of an expired authentication session; private-resource checks are unavailable.
- Retrieved the [public Hex OSV database](https://osv-vulnerabilities.storage.googleapis.com/Hex/all.zip): all 377 records are byte-identical to the previously evaluated explicit-version and semantic-range scan. All 51 direct/transitive locked package versions are unchanged. Zero matching advisories and zero unsupported applicable ranges. Evidence: `/tmp/resident-performance-hex.zip` and `/tmp/render-diagnostics-hex-result.json`.
- Retrieved the [official OTP advisory API](https://api.github.com/repos/erlang/otp/security-advisories?per_page=100): all 70 records are unchanged. Evidence: `/tmp/resident-performance-otp.json`.
- Rechecked runtime installation: OTP 29.0.1, ERTS 17.0.1; ssl 11.7.1, ssh 6.0, inets 9.7, snmp 5.20.4, eldap 1.3, asn1 5.5, public_key 1.21.1, megaco 4.9, stdlib 8.0, erl_interface 5.8, ftp 1.2.5.

The **40 pre-existing local OTP findings remain**. The exact identifiers,
affected/installed versions, patched component versions and exposure conditions
are recorded in the [runtime advisory table](qgenda-oct12-security-review.md#pre-existing-host-runtime-findings),
verified against fresh official data. Complete patched releases are 29.1.1,
28.5.0.7 or 27.3.4.18. Repository tooling, CI and deployment already pin 28.5.0.7;
the shared Homebrew runtime remains unchanged. Actual production runtime is
unverified. Outgoing TLS may reach affected SSL/public-key/ASN.1 components;
exploit prerequisites and production exposure remain uncertain. Application
SSH/SFTP, SNMP, LDAP, Megaco and FTP use was not observed.

No compatible locked-dependency security upgrade is indicated. No npm manifest
or lockfile exists in assets. Vendored/Git assets, operating-system packages,
undisclosed issues and actual production runtime are outside the Hex comparison.
This is not a claim of comprehensive application security.

Independent source review confirms the resident page still uses complete
schedule evidence, original raw date-slot boundaries and incoming coverage from
other schedules. Its full career entries and statistics remain available.
Coworker results are cached only in the individual LiveView after a successful
first load, including empty results. No shared user-specific cache is added.

The interval optimization normalizes occupancy endpoints only, preserving
original rotation maps and inclusive reversed-range membership. It uses merged
numeric intervals and binary search rather than expanding dates or changing
task grouping/order.

Tracing adds only fixed `resident` lifecycle/metric labels and four fixed phase
names with bounded numeric counters. Resident parameters, names, schedule IDs,
dates and task content are not exported. Schedule render diagnostics and browser
latency ingestion are not widened to resident-specific payloads.

The audit log's current ambiguous ownership warning observes the reviewed
interval source edit during a concurrent browser-verification command. The
browser command does not edit source; the change matches the implementer's
work. No unauthorized source/test edit is evidenced.
