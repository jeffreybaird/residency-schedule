# Schedule cache security review — October 13, 2026

The independent reviewer refreshed public advisory data for this PR at 14:23 UTC.

- `mix hex.audit`: exit 0, no retired packages. Retirement checks are not vulnerability scans.
- Downloaded the public [bulk OSV Hex database](https://osv-vulnerabilities.storage.googleapis.com/Hex/all.zip), then compared all **51 direct and transitive locked Hex versions** locally against **377 records**, excluding withdrawn advisories and checking explicit versions and semantic version intervals. **Zero matching advisories; zero unsupported ranges for these packages.** No project dependency metadata was uploaded. Evidence: `/tmp/schedule-cache-hex.zip` and `/tmp/schedule-cache-hex-result.json`.
- Refreshed the [official OTP advisory API](https://api.github.com/repos/erlang/otp/security-advisories?per_page=100): **70 records**, unchanged from the earlier tracing review. Evidence: `/tmp/schedule-cache-otp.json`.
- Rechecked the local executable with `elixir -e`: OTP **29.0.1**, ERTS **17.0.1**; component versions remain ssl 11.7.1, ssh 6.0, inets 9.7, snmp 5.20.4, eldap 1.3, asn1 5.5, public_key 1.21.1, megaco 4.9, stdlib 8.0, erl_interface 5.8 and ftp 1.2.5.

The **40 pre-existing local OTP findings remain**. Their advisory identifiers,
installed/affected versions, patched component versions and exposure conditions
are listed in the [complete runtime advisory table](qgenda-oct12-security-review.md#pre-existing-host-runtime-findings),
verified against today's unchanged official data and current component versions.
Patched OTP options covering them are **29.1.1**, **28.5.0.7**, or **27.3.4.18**.
Repository `.tool-versions`, CI and deployment already pin **28.5.0.7**; the
shared Homebrew executable is separate and is not modified by this PR.
Production's actual runtime remains unverified. Outgoing TLS can reach affected
SSL/public-key/ASN.1 components; exploit prerequisites and production exposure
remain uncertain. Application use of SSH/SFTP, SNMP, LDAP, Megaco and FTP was
not observed.

No compatible locked-dependency upgrade is indicated. There is no npm manifest
or lockfile in `assets`. Git/vendored assets, operating-system packages,
undisclosed issues and actual production runtime are outside this Hex scan.
This report does not claim comprehensive application security.

## Cache and database review

The prepared cache contains only shared schedules, date slots and unified
resident rows/cells. Socket state, users, roles, filters and modal state remain
per request. The cache is process-local and does not add an external export path.
Four completed entries and four in-flight keys, each with at most 64 waiters,
bound retained cache bookkeeping. Individual grid size depends on schedule data.

Committed database revision and date partition the cache. Builders use the actual
dynamic repository, run in read-only repeatable-read transactions, and verify the
revision again before publication. Stale results retry within a fixed limit;
fallback builds are coherent and uncached. Failed or killed owners release
waiting callers. Coordination retry count is also bounded. Dead or timed-out
waiter references occupy their bounded slots until the build terminates.

The migration adds transactional statement triggers to `schedules`, `residents`,
`schedule_residents`, `rotations`, `shift_overrides`, `detailed_activities` and
`detailed_activity_sources`. Five existing mutation transaction entrypoints
acquire the revision lock before any other row locks, avoiding the inversion
between an editor holding schedule rows and an import holding the revision row.
Future explicit-lock mutation transactions must follow the same ordering.
Writes serialize on the revision row for their transaction duration.

The revision-suppression setting is a trusted database-session mechanism used
only by test fixture setup; no application request or production configuration
sets it. Sandbox repositories and explicit caller transactions always bypass
shared caching. Dedicated ordinary-pool integration tests retain active triggers
and verify all seven tables, real commit/rollback visibility, failed and successful
admin edits, and concurrent editor lock ordering.

Audit review found ambiguous runner entries overlapping owner edits: migration
scaffold generation during the baseline benchmark, and spec-writer integration
test corrections during disposable-database cleanup and the after benchmark.
The corresponding owner operations and messages account for those edits; no
unowned source or test edit was established.
