# Database recovery tooling verification

Status: implementation, authoritative tests and bounded operational rehearsal
independently accepted on October 17, 2026.
Branch: `codex/phase0-database-recovery`, based on merged PR #78 at
`81a91e70ccacfdd3478cc183da3cc9f31c673b8a`.

The shared role-owned workflow applies: spec writer owns tests/fixtures, runner
records red and green, reviewer accepts the test hash before implementation and
independently reviews the final changes. The orchestrator does not edit source or
tests. Operational results belong in [the recovery record](phase0-database-recovery.md).

## Intended bounded contract

The Ruby CLI backs up only an explicitly named synthetic source on the verified
staging PostgreSQL cluster. It exports a coherent table snapshot for the dump and
verification manifest, encrypts both using an operator public GPG recipient,
and records checksums and recovery timestamps. Decryption happens off-host with
the private key. Restoration uses a fresh disposable database and restricted role;
existing databases/roles, production/demo targets and source names are rejected.
The active persistent staging database is never overwritten or reseeded.

Verification compares all supported table contents and relevant schema,
constraints, sequences, extensions and migration state. Unsupported object scope
must fail explicitly. Sequence equality requires the synthetic source write
freeze because sequence state is not MVCC snapshot state. Private outputs and
logs must not expose credentials, rows, feed tokens or raw database diagnostics.

This bounded rehearsal does not install production backups, retention automation,
monitoring, WAL archiving or PITR. It cannot establish a production 15-minute RPO.

## Evidence

Accepted tests, authoritative red/green and security scope are recorded below.
Final operational evidence and independent final acceptance are recorded below.

## Accepted contract and authoritative red

The independent reviewer accepted these frozen SHA256 hashes on October 17:

- `test/deploy/database_recovery_test.rb`:
  `b30864b7ee19132b9c3eed81ff463a53b33bd1fe42597e053529f123134c5480`.
- `test/deploy/fixtures/recovery_enrichment.sql`:
  `67eae29320a0e497e332d17fb2bd3d0dc5649ab452e3cdcdc6f88d96063a1d97`.
- `test/deploy/fixtures/recovery_semantics.sql`:
  `e77f019e613e5c93b10d2ab958d7799fb27a4110af12f3022c47737ac685201c`.

The runner executed
`~/.rubies/ruby-3.3.12/bin/ruby test/deploy/database_recovery_test.rb`
before implementation: exit 1, **33 runs, 94 assertions, 25 failures, zero errors
or skips**. Happy paths failed because `deploy/database_recovery.rb` did not yet
exist. An earlier 32-test candidate was superseded by the reviewed additive
ciphertext/manifest-pairing case. No accepted assertion was weakened.

The reviewer checked fixture SQL against the actual schema and persistent
synthetic fixture. Enrichment is limited to a disposable recovery source; parent
operations must additionally verify the actual cluster and exact database name.
The semantic fixture checks nonempty approved request/override/notes linkage,
provenance, OAuth/magic-link/feed preservation and the April 5–18 vacation chain.
The implementation role was authorized only after this accepted contract and red.

## Security review scope

The reviewer and runner refreshed `MIX_ENV=test mix hex.audit` on October 17;
both checks reported no retired packages or published Hex advisories. This is a
Hex dependency check, not a complete OS, RubyGems, PostgreSQL or GPG audit.

The local active Ruby is 3.3.12 with `resolv` 0.3.2. This fixes
[CVE-2026-80212 and CVE-2026-80213](https://www.ruby-lang.org/en/news/2026/08/27/multiple-vulnerabilities-in-resolv/),
which affect <=0.3.1 and 0.4–0.7.1; patched versions are 0.3.2 and 0.7.2.
The backup implementation does not directly use Resolv DNS resolution.

The workstation PostgreSQL 17.10 clients predate the 17.11 fixes including
CVE-2026-19385 (`pg_dump` buffer overflow), CVE-2026-18408 (`psql` unrestrict
handling), and CVE-2026-16241 (ECPG integer underflow). No ECPG client is used by
this tool path. These are pre-existing local findings; local PostgreSQL binaries are
excluded from the rehearsal path. Actual database commands use staging's
PostgreSQL 16.15 server and clients, the fixed 16-series level in
[the PostgreSQL security table](https://www.postgresql.org/support/security/16/).

Staging's Ubuntu GPG package is `2.4.4-2ubuntu17.6`; its installed changelog
records vendor fixes for CVE-2026-57062 (.6) and CVE-2025-68973 (.4).
`libgcrypt20` is `1.10.3-2ubuntu0.2`, meeting the vendor fixes for
[CVE-2026-41989](https://ubuntu.com/security/notices/USN-8319-1) and
[CVE-2024-2236](https://ubuntu.com/security/notices/USN-8711-1).
The local GPG is 2.5.21 with libgcrypt 1.12.2. Later
[GPG 2.5.24 changes](https://lists.gnupg.org/pipermail/gnupg-announce/2026q3/000516.html)
include gpgsm debug, dirmngr and smartcard parser fixes outside this offline
known-recipient batch encryption/decryption operation; this does not establish
that every installed GPG component is fully patched. The synthetic rehearsal key
expires in 45 days and is not a production recovery key.

## Reviewed regression additions

Independent source review identified missing sequence definitions/trigger enabled
state, unvalidated constraint rejection, direct TCP recovery-role cluster identity,
and database-side logging protection before credential-bearing role creation.
The spec writer added regressions without weakening the initial assertions.

The final accepted test hash supersedes the initial test hash:
`a9a2a0ce4220b2d94faf23b3f86f7d4332f39888eeade1a6baf132241d1abbf9`.
Both SQL fixture hashes remain unchanged. The runner recorded the preceding
41-test suite red: **41 runs, 559 assertions, six expected failures, zero errors
or skips**. A final additive valid-password case containing both an apostrophe
and backslash then failed independently: **one run, 12 assertions, one expected
failure**, because the same password-creation backend had not explicitly enabled
`standard_conforming_strings`. The reviewer accepted the exact final 42-test hash
against both red results before implementation of these fixes.

The logging test models separate SQL commands in the same psql backend. Sending
logging settings and a password in a single query string would risk logging that
query before the settings take effect. Guards must precede the credential
statement in that same session; server error, duration and sampling logs also
need session-local suppression. Actual external/audit extensions remain an
operator-reviewed boundary.

Local Ruby test commands use `TMPDIR=/private/tmp` so macOS temporary paths are
canonical. The default `/var/folders` path has a symlink ancestor; the source's
private-path guard remains strict. A transient spec-writer setup normalization
was reverted, leaving the accepted test bytes unchanged before regression edits.

The existing `.github/workflows/ci.yml` already validates non-main branches and
PRs to main. The only CI change adds the new recovery test invocation beside the
existing deployment suite; no duplicate workflow, deployment trigger,
environment/runtime secret or production job is introduced.

## Exact numeric fingerprint regression

Independent review found that parsing PostgreSQL JSON into Ruby Float values and
then re-encoding it could collapse distinct high-precision numeric or nested JSON
values. The spec writer added a representative exact-text regression, preserving
all prior 42 tests. The runner's selected red recorded **one run, eight assertions,
one expected raw-digest failure**, zero errors/skips. It distinguishes
`9007199254740992.1` from `9007199254740992.2` without changing row count.

The latest accepted test SHA256 is
`9de8e60decdfbbf0d77ba617265d60d77e88b34c99da2d78c7bbb5bbfb04bc5a`
(**43 tests**), superseding the 42-test hash above. Fixture hashes remain unchanged.
The reviewer accepted this exact hash before the source correction. Table
fingerprints now hash the raw canonical PostgreSQL JSON text, removing only the
psql output newline; parsing is used only to validate/count rows. The source and
restore queries use the same PostgreSQL version and DateStyle/UTC settings.
Early exploratory synthetic bundles used the preceding hash representation and
are not the final operational recovery evidence.

The initial cached Linux Ruby 3.3.12 image contained `resolv` 0.3.1, affected
by CVE-2026-80212/80213. Its initial regression invocation used `--network none`
and no DNS. The runner then applied the compatible 0.3.2 fix offline from the
cached gem into an isolated test image, without changing host or application
runtimes. Active Ruby 3.3.12 / resolv 0.3.2 was confirmed inside the new image;
local and live operational runtimes also use patched 0.3.2. The final regression
result on that patched image is recorded below. This does not establish a clean
all-gem scan.

## Authoritative green and final source

The final source SHA256 is
`2054ff62f7fee74eae96b7625ebc4c549eb26ed90df00f173054d065baf17fd4`.
The runner verified that it and the accepted 43-test hash were unchanged before
and after the final full suite:

- `TMPDIR=/private/tmp ~/.rubies/ruby-3.3.12/bin/ruby test/deploy/database_recovery_test.rb`:
  **43 runs, 645 assertions, zero failures/errors/skips**, 66.936 seconds.
- Existing deployment regression suite in the cached Linux Ruby 3.3.12 container
  with real `flock`, a read-only repository mount and networking disabled:
  **48 runs, 10,664 assertions, zero failures/errors/skips**, 40.01 seconds.
- Ruby source/test syntax, Bash deployment syntax, changed CI YAML parsing,
  `git diff --check`, read-only Mix formatting, compile with warnings as errors,
  strict Credo (320 files), unused-dependency check and fresh Hex audit passed.
  The final precision-only Ruby change was followed by the full 43-test suite,
  syntax, whitespace and formatting checks; unchanged broader checks were not
  repeated without a new concern.

Source and test owners separately ran the required correcting `mix format --force`
on their owned Elixir paths before the read-only checks. There were no Elixir
source/test changes. No RuboCop or additional runtime dependency was introduced.

The independent reviewer inspected all three new audit records. All are marked
ambiguous due to overlapping commands; none is an exclusive violation. The actual
reviewer/runner commands were read-only inspection or test execution. Their
observed changes match the spec writer's notified contract additions and the
implementer's agreed CI addition/removal timeline. No evidence of parent,
reviewer or runner source/test edits or hook evasion was found. Retain the audit
records unchanged with the work.

## Actual final-tool rehearsal

The parent operator repeated the complete flow using the exact final source hash
above after the numeric correction. PostgreSQL 16.15 produced a fresh encrypted
snapshot; operator-side decryption kept the private key off-host, and a new
restricted-role database restored and verified all 18 tables and 16 sequences.
The current immutable `81a91e7` release then passed authenticated HTTP and real
WebSocket schedule interactions plus the accepted semantic fixture on that
isolated restored database. Decryption through authenticated semantic release
verification took **54.524105 seconds** for this small synthetic dataset.

Actual negative probes rejected sequence-definition, trigger-enabled-state and
same-count note drift; reverting each mutation restored successful verification.
Existing destinations, the wrong cluster and corrupted encrypted input were
rejected. Role isolation, private-key absence, password absence from protected
PostgreSQL logs and unchanged original persistent staging were independently
checked. Temporary service/listener and plaintext copies were removed.

[The operational recovery record](phase0-database-recovery.md) contains exact
snapshot/ciphertext identities, component timings, retained recovery references,
cleanup and limitations. These measurements do not demonstrate production-scale
RTO, recurring production backups, 15-minute RPO or PITR.

## Patched isolated test runtime

The final existing-deployment regression run used the compatibly patched image
`phase0-recovery-ruby:3.3.12-resolv-0.3.2`, image identity
`sha256:135e4c6c5c7de097c8b4e78e64a58902dd90bd76201acb54029f4997dfad171a`.
The runner applied cached `resolv` 0.3.2 entirely offline and confirmed active
Ruby 3.3.12 / resolv 0.3.2 before running the suite with networking disabled,
a read-only repository mount and real Linux `flock`:
**48 tests, 10,664 assertions, zero failures/errors/skips**, 40.376 seconds.
This supersedes the initial unpatched-image regression result. No host,
application, source or test files changed during this runtime correction.

## Independent final acceptance

The independent reviewer accepted the final source, frozen tests/fixtures, CI,
runbook, operational record, final diff and audit log on October 17. No findings
remain open for this bounded synthetic recovery delivery. Exact source/test
hashes above remained unchanged, both authoritative suites passed on the final
supported runtimes, the fresh Hex audit passed, and actual final-tool recovery,
semantic/authenticated checks, negative probes and cleanup passed.

This acceptance permits the focused commit and draft PR. It does not authorize
production deployment or establish production backup/PITR/recovery objectives.
