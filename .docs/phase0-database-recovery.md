# Phase 0 database recovery — October 17, 2026

> Historical record. The owner canceled the Phase 0 recovery program on October
> 21, 2026. Pending tasks, targets, activation proposals and gates below are
> retired, not a continuation queue. See the [current recovery decision](schedule-adapter-recovery-decision.md).

Status: tooling and isolated synthetic restore rehearsal independently accepted.
Production database backup/restore and the accepted production database RTO/RPO
are not yet proven.

Branch `codex/phase0-database-recovery` starts at current `main`,
`81a91e70ccacfdd3478cc183da3cc9f31c673b8a`, which merged
[PR #78](https://github.com/jeffreybaird/residency-schedule/pull/78).
The requester authorized continuing database recovery work on a new branch.

## Completed predecessor

PR #78 merged on October 17 at 10:34:19 UTC.
[Main workflow 39025404937](https://github.com/jeffreybaird/residency-schedule/actions/runs/39025404937)
passed tests, build, staging, production and demo. The merge tree exactly matched
reviewed head `c05a31b00509f71da57b9ea08207fd9a6921c7eb`.

All three installations received artifact SHA256
`60c6d209588bac88725ab9efdab2480b545ff976ca42e7a7edcbbda9c474c657`.
Selected configuration versions were staging `39025404937-1.znZtlE`, production
`39025404937-1.5smtow`, and demo `39025404937-1.kOBuNx`.
Actual retained archive checksums and release/configuration metadata matched.
Production/demo preserved signing keys, effective cookies and existing provider
and database secrets. Private modes and empty configuration inboxes passed.
Both services returned HTTP 200 locally and over public HTTPS. Authenticated
production reads reported build `81a91e7`, four schedules and 32 residents.
All 18 staging table fingerprints and the original authenticated HTTP/WebSocket
session survived the deployment. No synthetic production records were written.
Both live databases retain 22 migrations, ending `20261013143545`.

These observations complete the bounded PR #78 rollout; they do not establish
database restore, PITR, semantic rollback or broader Phase 0 completion.

## Recovery baseline and scope

Read-only inspection on October 17 found PostgreSQL 16.15 on both hosts.
Production is approximately 16 MB; staging is approximately 9 MB with 18 public
tables and extensions `citext` 1.6 and `plpgsql` 1.0. Both clusters still report
`archive_mode=off` and `wal_level=replica`. No application database backup timer
was observed. The OS `dpkg-db-backup` timer backs up package metadata and is not
application database backup evidence. This remains a bounded inventory rather
than proof that no external backup exists.

The installed production/demo runtime configuration does not specify an external
roster path, and neither installation has the default `data/roster.csv` file.
No roster contents were read for this check. If a roster/mapping file is added
later, it needs separate protected retention; a database dump cannot contain it.
Code and configuration recovery copies from PR #78 remain separate from database
backups.

The first delivery provides encrypted logical backup and guarded isolated
restore tooling, then exercises it with synthetic data on the separate staging
host. A disposable source adds meaningful notes, approved coverage relationships
and authentication state without changing the persistent staging baseline.
Only newly created disposable recovery databases and restricted roles may be
restore destinations. Existing databases and live production/demo/staging
destinations must be rejected before mutation.

The operator private GPG key stays off-host. Only the public recipient is
installed on staging. Encrypted backups are retrieved to private operator
storage; decryption happens there. Synthetic plaintext may return through SSH
into a temporary private directory for the disposable restore. That flow does
not authorize copying production snapshots into staging. Encryption integrity
and checksums do not authenticate the sender; this rehearsal trusts only the
operator-created backup through restricted storage and SSH transport.

Logical dump recovery stops at its recorded snapshot. PostgreSQL documents that
[logical dumps cannot be replayed with archived WAL](https://www.postgresql.org/docs/16/continuous-archiving.html).
A single successful restore does not prove a recurring 15-minute recovery point.
Production backup scheduling, off-host retention, key custody, failure/freshness
alerts and a supported PITR/replay method remain explicit operational gates.
No production database configuration change or service restart is part of this
rehearsal.

## Verification and operational evidence

The [tooling verification record](database-recovery-tooling-verification.md)
tracks accepted tests, authoritative red/green runs and independent review.
The final real rehearsal used the exact independently reviewed tool SHA256
`2054ff62f7fee74eae96b7625ebc4c549eb26ed90df00f173054d065baf17fd4`.
The accepted test SHA256 is
`9de8e60decdfbbf0d77ba617265d60d77e88b34c99da2d78c7bbb5bbfb04bc5a`.
The authoritative runner reported **43 tests, 645 assertions, zero failures,
errors or skips**. Existing deployment tests and the remaining checks are
recorded in the tooling verification document.

On October 17, the accepted enrichment fixture was applied only to a fresh
disposable source copied from synthetic staging. The operator independently
verified the actual staging cluster identity and absence of a production
installation before executing it. The accepted semantic SQL passed against that
source: all 14 days of the April 5–18 vacation chain, approved coverage and both
notes linked to the override, activity provenance, password hash and feed/OAuth
records. The persistent staging database was not changed. This establishes the
source baseline, not a successful restore.

### Final backup and restore

The operator ran PostgreSQL 16.15 tools as the local `postgres` OS user, with
private configuration and workspace directories. The disposable source had no
application writer. The tool held an exported read-only snapshot for table
inventory and the custom-format dump; the separate write-freeze assertion covered
non-MVCC sequence state. No database authentication rules were broadened.

| Observation | Final measured result |
| --- | --- |
| Snapshot start | `2026-10-17T11:23:39.604554Z` |
| Encrypted backup completion | `2026-10-17T11:23:42.223094Z` |
| Backup duration | 2.619 seconds |
| Restore duration | 1.071 seconds |
| Initial restored inventory verification | 3.947 seconds |
| Off-host decryption through authenticated current-release/semantic verification | **54.524 seconds** |
| Restored coverage | 18 tables, 16 sequences, 22 migrations; maximum migration `20261013143545` |

Ciphertext SHA256 identifiers:

- Database dump: `bbc1675ef613bb518cbe8119fe340e96110a5c2e0549f7c77e5c5b70803643b2`.
- Private manifest: `d778e57820057d846ffc3ae62db7f792acd5695851b714e5ce6567729dc5aa45`.

Both encrypted files were copied off-host through authenticated SSH, checked and
decrypted in private operator storage. The private key never went to the database
host; actual public-keyring inspection confirmed no secret key there. Only the
protected synthetic plaintext dump and manifest returned over SSH for restoration.
The final destination was a newly created database and login role, distinct from
the exploratory probe. The role had no superuser, database/role creation,
replication or RLS-bypass privilege and could not CONNECT to either the source or
live staging database. The narrow `pg_control_system()` grant verified that its
direct TCP connection reached the expected cluster.

The initial and post-session comparisons matched all supported table contents,
sequence values/definitions, schema objects, trigger enabled states, validated
constraints, extensions and migration state. Database ownership/ACLs are
deliberately remapped to the restricted recovery role; inventoried source roles
are not recreated with their credentials.

The exact current immutable release from PR #78 ran against the restored database
on a separate loopback port and Erlang node. Authentication stayed enabled; email
used the staging test sink, and assistant/telemetry integrations were disabled.
The original staging login cookie successfully accessed the restored schedule and
completed real WebSocket join, year filtering and academic-year switching. The
semantic SQL independently passed the 14-day vacation chain, linked approved
coverage/notes, activity provenance and authentication/feed records.

The 54.524-second measurement starts immediately before off-host decryption and
ends after authenticated and semantic verification, using the operator machine's
monotonic clock. It includes transfer of the synthetic plaintext to the isolated
host, restore, inventory verification and current-release startup. The roughly
9 MB synthetic source and controlled write freeze do not establish production
RTO, representative-volume behavior, a production write freeze or the 15-minute
production RPO. The observed freshness command passed at age 179.029 seconds;
it is not an installed recurring backup or alert.

### Negative probes and cleanup

After stopping the temporary recovered service, actual disposable-database probes
changed a sequence increment, disabled a cache-revision trigger and changed a
coverage note without changing its row count. Each made verification fail. Each
change was reversed and verification passed again, including all row hashes.
Reusing the existing restore destination was rejected before changes. A wrong
cluster was rejected before backup output existed, and a corrupted off-host
ciphertext copy was rejected before decryption output existed. A private scan of
PostgreSQL logs found no generated recovery-role password; no raw log contents or
secret values were printed.

Temporary plaintext dump/manifest files on both machines and the bootstrap dump
were removed. No plaintext workspace or temporary loopback listener remains.
Encrypted copies and private configurations remain in restricted operator/host
storage under the rehearsal reference `phase0-recovery-20261017`; the synthetic
databases remain available for review with the temporary service stopped.
The rehearsal encryption key expires in 45 days and is not a production key or
an approved long-term backup-custody arrangement.

The original persistent staging database still matches all 18 pre-rehearsal table
fingerprints, including identities, feed tokens, accounts and history. Production
received only bounded read-only inventory queries. No production backup export,
data copy, restore, service restart or configuration mutation occurred.

An earlier exploratory backup/restore passed real SQL and permissions checks but
was superseded when independent review found that Ruby numeric conversion could
lose precision during fingerprint generation. The final tool hashes PostgreSQL's
raw canonical JSON text and parses only the row count; the added precision
regression and the complete final backup/restore above passed. Only the final
tool and bundle identities are acceptance evidence.

## Remaining acceptance gates

- Demonstrate the accepted 60-minute database RTO with reconciliation at
  representative scale; a small synthetic measurement alone is insufficient.
- Establish and measure production backups and off-host retention, including
  recoverable key custody and failure/freshness monitoring.
- Demonstrate the accepted maximum 15-minute lost-write RPO or obtain an explicit
  revised objective. Neither logical backup existence nor binary rollback is
  proof of this limit.
- Complete the later Phase 0 write-protection, semantic/operator rollback,
  additive-schema compatibility and disaster-recovery steps separately.
- Resolve existing production PostgreSQL superuser use through a reviewed
  privilege transition.
