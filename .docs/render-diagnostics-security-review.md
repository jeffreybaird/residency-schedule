# Render diagnostics security review — October 13, 2026

Independent advisory data was refreshed for this PR.

- `mix hex.audit`: exit 0, reported **no retired or security advisory packages**. Hex also warned that its authentication session expired and continued anonymously; private-resource checks would be unavailable. The separate public bulk comparison below succeeded.
- Downloaded the current [bulk OSV Hex database](https://osv-vulnerabilities.storage.googleapis.com/Hex/all.zip). All **377 records** and all **51 direct/transitive locked Hex versions** were identical to the previously evaluated explicit-version and semantic-range scan: **zero matching advisories, zero unsupported applicable ranges**. No dependency metadata was uploaded. Evidence: `/tmp/render-diagnostics-hex.zip` and `/tmp/render-diagnostics-hex-result.json`.
- Refreshed the [official OTP advisory API](https://api.github.com/repos/erlang/otp/security-advisories?per_page=100): **70 unchanged records**. Evidence: `/tmp/render-diagnostics-otp.json`.
- Rechecked the executable using `elixir -e`: OTP **29.0.1**, ERTS **17.0.1**, ssl 11.7.1, ssh 6.0, inets 9.7, snmp 5.20.4, eldap 1.3, asn1 5.5, public_key 1.21.1, megaco 4.9, stdlib 8.0, erl_interface 5.8 and ftp 1.2.5.

The **40 pre-existing local OTP findings remain**. Their exact identifiers,
installed/affected versions, patched component versions and exposure conditions
are in the [runtime advisory table](qgenda-oct12-security-review.md#pre-existing-host-runtime-findings),
verified against refreshed official data and the current executable. Patched
OTP releases covering them are **29.1.1**, **28.5.0.7**, or **27.3.4.18**.
Repository tooling, CI and deployment already pin **28.5.0.7**; the shared local
Homebrew runtime is separate and unchanged. Actual production runtime is
unverified. Outgoing TLS may reach affected SSL/public-key/ASN.1 components;
exploit prerequisites and production exposure remain uncertain. Application
SSH/SFTP, SNMP, LDAP, Megaco and FTP use was not observed.

No compatible locked-dependency upgrade is indicated. No npm manifest or lockfile
exists in `assets`. Vendored/Git assets, operating-system packages, undisclosed
issues and the actual production runtime are outside the Hex comparison. This
review does not claim comprehensive application security.

The source review confirms fixed render fields, allowlisted event names, numeric
workload/process measurements and a validated deployment SHA. Encoding delegates
once and exports only fixed labels, duration and byte length; malformed optional
diagnostics preserve the application's result or original exception. Incoming
decoding and broadcast fastlane remain Phoenix delegates. Render correlation is
one-shot and process-local; unproven info/async causes are `unknown`. The local
profiler is opt-in and compiled disabled in production.

The audit log's sole new ownership warning observed a blank-line test formatting
change during an implementer read/test command overlapping the test writer's
formatting. The diff changes no assertions and provides no evidence of an
unauthorized source/test edit.
