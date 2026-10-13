# Operation tracing security review — October 13, 2026

Independent reviewer refreshed the advisory data before reviewing the implementation.

- `mix hex.audit`: exit 0, no retired packages. The sandbox attempt could not open Mix's local TCP socket; the native escalated read-only audit succeeded. Retirement checks are not vulnerability scans.
- Downloaded the public [bulk OSV Hex database](https://osv-vulnerabilities.storage.googleapis.com/Hex/all.zip), then compared all **51 direct and transitive locked Hex versions** locally against **377 records**, excluding withdrawn advisories and checking both explicit versions and semantic version intervals. **No matching advisories; no unsupported ranges for these packages.** The download sent no project dependency metadata. Evidence: `/tmp/operation-tracing-hex.zip` and `/tmp/operation-tracing-hex-result.json`. Decimal remains patched at 3.1.2.
- Refreshed the [official OTP security advisory API](https://api.github.com/repos/erlang/otp/security-advisories?per_page=100): **70 records**, identical to the previous day's downloaded data. `elixir -e` verified OTP 29 / ERTS 17.0.1 and the same component versions as the previous review: ssl 11.7.1, ssh 6.0, inets 9.7, snmp 5.20.4, eldap 1.3, asn1 5.5, public_key 1.21.1, megaco 4.9, stdlib 8.0, erl_interface 5.8 and ftp 1.2.5. Evidence: `/tmp/operation-tracing-otp.json`.

The **40 pre-existing local OTP 29.0.1 findings remain**. The complete advisory identifiers, installed/affected versions, patched component versions and individual exposure conditions are in [the runtime advisory table](qgenda-oct12-security-review.md#pre-existing-host-runtime-findings), verified against today's identical official data and runtime versions. Patched OTP options covering those findings are **29.1.1**, **28.5.0.7**, or **27.3.4.18**. Repository `.tool-versions`, CI and deployment already pin 28.5.0.7; the local Homebrew executable is separate. Production's actual runtime is unverified. Outgoing TLS can reach affected SSL/public-key/ASN.1 components; exploit prerequisites and production exposure remain uncertain. Application use of SSH/SFTP, SNMP, LDAP, Megaco and FTP was not observed.

No compatible locked-dependency upgrade is indicated by this fresh review. The host-runtime findings were routed to the orchestrator; changing a system-wide Homebrew runtime is outside the application source change. The user should select the already-pinned patched runtime locally and verify the deployed release's actual runtime.

There is no npm manifest or lockfile in `assets`. Git/vendored Heroicons and other vendored assets, operating-system packages, undisclosed issues and the actual production runtime are outside this Hex scan. This is not a claim of comprehensive application security.

## Implementation review

The independent source review verified fixed operation/phase names, fixed count
and database timing keys, allowlisted HTTP method/status, and no SQL, parameters,
URLs, headers, event payloads, exception messages or stacktraces in the new
export path. Exceptions retain their application semantics and set only the
fixed error status. Span events and links remain disabled. The named provider,
bounded asynchronous exporter and opt-in supervision remain in use.

Decoded-OTLP tests enforce the exact attribute-key allowlist and private-value
exclusion, plus real static/connected callbacks, inclusive query counters,
nonempty parallel preload results, context restoration after success/failure,
and the 128-span budget. Explicit preload hooks retain caller precedence, and
the operator guide documents their attribution limitation. See the separate
[verification record](operation-tracing-verification.md) for authoritative
test results and accepted hashes.

Audit review found two carried-over ambiguous main-role entries from the
authorized `git pull --ff-only origin main` and its overlapping `git ls-remote`
check. Both list the fetched main-branch changes; they are not evidence of
unowned implementation edits. Current spec-writer and implementer formatting
entries show no ownership violations.
