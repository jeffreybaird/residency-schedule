# Production logical backup and off-host checks

Status: tooling contracts are accepted; synthetic restore, deadline and
scheduled-cadence rehearsals passed. Original tooling CI passed; follow-up-head
CI is pending and tracked in the operational record. No paid storage, production key, production role,
service or timer is activated by these files.
Operational decisions and results belong in
[the production backup record](phase0-production-backups.md).

This delivery follows merged PR #79. Its synthetic recovery CLI and accepted
contracts remain unchanged. The new online backup format supports ordinary
writes; it deliberately has no synthetic write-freeze assertion or claim that
sequence values share an MVCC snapshot. Do not feed it into the earlier synthetic
restore CLI. A reviewed restricted restore procedure must consume the decrypted
custom-format dump and verify its private digest separately.

## Source and storage boundaries

The source helper runs as root from a root-owned file and mode-600 configuration.
It opens the existing deployment lock read-only without changing, replacing or
unlinking its mode-600 inode. PostgreSQL subprocesses run only through the fixed
`runuser -u rs_backup` peer identity. That role receives SELECT access for the
inspected application schema and future objects created by the verified owner,
without database/role creation, superuser, replication, sequence mutation or
sensitive-catalog credentials. It must pass actual permission probes with the
read-only default explicitly disabled, so a default GUC cannot hide excessive
grants.

The restricted connection checks the actual cluster identifier, exact database
and primary status before exporting a repeatable-read, read-only snapshot.
The dump and row/schema inventory use that held snapshot while normal writers
continue. Sequence definitions are inventory; sequence state in the dump is
archive-authoritative because sequence increments are not MVCC state. The helper
streams dump bytes directly into GPG and checks both process exits. Production
plaintext dumps and manifests are never written to the source disk.

Each PostgreSQL launch receives internally generated timeouts from the remaining
monotonic job budget, reserving two seconds for connection startup. Ambient PG
settings are removed. A one-second client-connection check detects disconnected
clients during active queries on the rehearsed Linux/PostgreSQL 16 path.
`pg_dump` resets its statement/lock/idle-transaction startup timeouts, so it also
receives its explicit remaining lock-wait budget; its client-connection check and
the helper's process watchdog remain active. This does not establish a universal
per-statement timeout inside `pg_dump` or change global/role PostgreSQL settings.

Only the public encryption recipient exists on the source. GPG uses a dedicated
public-only home with automatic agent startup disabled. The durable private key
and recovery copies require a separate operator custody decision. Encryption and
checksums do not establish sender identity; restricted authenticated transport
and trusted operator-created input are the provenance boundary.

DigitalOcean Spaces is the prepared transport, subject to storage approval.
Use a private bucket, approved regional HTTPS endpoint and separate writer and
reader credentials. The writer key may have delete capabilities even though the
helper never calls deletion APIs. Versioning is recovery assistance, not object
lock or append-only storage. A compromised source administrator may poison future
backups; a broadly privileged storage credential may also delete versions.
No off-host pruning or lifecycle expiry is installed by this change.

## Commands and configuration

```text
ruby deploy/production_backup.rb run CONFIG.json
ruby deploy/production_backup.rb check CONFIG.json STATUS.json
```

The `production` profile requires the exact production database name, actual
configured cluster identity and production lock location. A separate `synthetic`
profile permits only the explicitly guarded disposable source names for tests.
Actual production-profile rehearsal uses a new isolated PostgreSQL cluster with
synthetic data and the literal database name; it does not weaken source guards or
copy production plaintext into staging.

The mode-600 JSON configuration uses these fields as applicable to each command:

- Identity/PG: `schema_version`, `profile`, `source_database`,
  `expected_cluster_identifier`, `pg_host`, `pg_port`, `psql_path`,
  `pg_dump_path`, `runuser_path`.
- Source files: `deploy_lock_path`, `spool_dir`, `source_status_path`,
  `gpg_path`, `gpg_home`, `gpg_recipient`.
- Transport: `aws_path`, `aws_credentials_file`, `region`, `endpoint`, `bucket`,
  `prefix`.
- Bounds: `deadline_seconds`, `max_age_seconds`, `max_spool_bytes`,
  `max_failed_bytes`, `max_object_bytes`, `max_download_bytes`,
  `max_recent_points`, `max_list_objects`, `scrub_interval_seconds`.

The off-host checker needs only its identity/transport/bounds fields and its
separate reader credential; it does not need PG access, GPG keys or the source
lock. Paths are canonical/private; unknown or duplicate fields and unsafe
credential-provider configuration fail closed. Credentials never appear in
arguments or exported values. The AWS CLI receives a generated private config,
explicit endpoint and disabled history/pager/prompt, with ambient credential
providers scrubbed. No project Python code, signing implementation or SDK gem is
introduced; AWS CLI 2 remains a separately verified maintained tool.

Executable validation returns the checked canonical target, and every spawn uses
that pinned path. Retargeting an original alias cannot change the chosen binary.
Production private inputs and state also require root-owned ancestors without
group/other write permission; putting a private leaf beneath a writable directory
is insufficient. The existing deploy-owned lock retains its separately reviewed
ownership policy and is opened read-only without following a leaf symlink.

## Completion, monitoring and retention

Each point has a date-partitioned, unpredictable unique object prefix. The helper
uploads the encrypted dump and encrypted private manifest, downloads both and
checks full SHA256/length, then publishes `complete.json` last and reads that
receipt back. An ETag, HEAD response or successful upload alone never establishes
completion. Failed/partial uploads cannot advance the recorded recovery point.

The independent checker discovers recent receipts with bounded pagination and
chooses the newest fully verified valid snapshot. A bad newer upload cannot
replace a still-available known-good point. Each new point requires full GET
verification. A protected cache may reuse verification only for exact provider
version IDs, while checking those exact versions remain available and scrubbing
full contents periodically. Missing, empty or literal `null` version IDs require
full GET on every check. A download budget bounds fallback transfer costs.

Freshness uses the verified snapshot's timestamp, never upload completion or the
current check time. The prepared schedule is five-minute source capture with a
150-second helper deadline, and a separate off-host one-minute check with a
900-second stale threshold. Failure status is local/structured until an external
alert destination is explicitly approved. Observation of healthy intervals is not
an unconditional RPO guarantee during a prolonged outage.

Source cleanup applies only to a successfully published, nondesignated temporary
bundle. Failed complete ciphertext and the previous verified success remain
protected; capacity checks fail rather than silently pruning recovery material.
Durable retention, quota/overage handling and any later cleanup policy require
an explicit operator decision. Keep designated recovery copies for their approved
window.

## Installation and rehearsal gate

The supplied systemd files are dormant templates. The root source service needs
only bounded capabilities for changing to the read-only peer user, reading the
private deployment lock and terminating its children. Home directories remain
hidden except for the lock's read-only bind; the trusted AWS bundle must be
outside the hidden home paths. The service has a 150-second helper deadline and
a 165-second systemd startup limit allowing bounded cleanup. The reader has no
PG/user-switching capabilities and uses an independent host/key/cache.

On the rehearsed systemd 255 host, the root source also needs
`AmbientCapabilities=CAP_SETUID` to retain its already-bounded UID-switching
capability after sandbox setup. The actual restricted PostgreSQL child must have
zero effective, permitted and ambient capabilities after the UID change. This
does not add `CAP_SETPCAP` or expand the bounding set. Both services disable core
dumps with `LimitCORE=0`; streaming does not eliminate every possible memory or
swap forensic exposure.

Before activation, prove the exact root unit with the actual restricted role,
public GPG ring and maintained AWS CLI against the isolated test cluster. Syntax
checking alone does not establish capability/PAM/mount compatibility. Rehearse
concurrent writes, transfer failures, corrupt data, stale/future points, cached
version deletion and credential denial. Actual Spaces permissions, versioning,
key recovery and provider compatibility remain activation gates; the loopback
S3 fixture does not prove those properties.

## Reviewed synthetic restore procedure

This rehearsal consumes the new online format directly. It is restricted to the
new isolated synthetic cluster recorded in the operational packet. Production
restore authorization is separate.

1. With the reader credential, fetch the selected receipt and both exact object
   versions. Verify ciphertext SHA256 and lengths. On the operator machine,
   decrypt into a fresh mode-700 directory containing only mode-600
   `database.dump` and `manifest.json`. Verify the plaintext dump SHA256 against
   `manifest.dump_sha256`. The private key stays off the source and restore host.
2. Confirm the manifest identifies the approved synthetic cluster before copying
   protected plaintext to that isolated host. Run the accepted readonly
   `production_backup_restore_checks.rb preflight CONFIG DIRECTORY`. It checks
   the actual cluster/port/database, private bundle pairing and absent target.
   Separately verify the intended fresh restore role is absent. Stop on any
   existing target or role; never drop or overwrite it.
3. As the isolated cluster administrator, create the fresh restricted LOGIN role
   with no superuser, database creation, role creation, replication, inheritance
   or RLS bypass. Supply its random password through private psql stdin. In the
   same backend, first set `standard_conforming_strings=on`,
   `log_statement=none`, `log_min_error_statement=panic`, `log_duration=off`,
   `log_min_duration_statement=-1`, `log_min_duration_sample=-1`,
   `log_transaction_sample_rate=0` and `log_statement_stats=off`. Independently
   check external auditing and other credential logging controls; these session
   settings do not disable arbitrary audit extensions.
4. Create the fresh database from `template0`, owned by that role, outside a
   transaction. Revoke PUBLIC database access. Grant only the restore database's
   `pg_control_system()` execution needed for identity verification. Use a
   temporary mode-600 passfile with colon/backslash escaping and direct TCP as
   the restricted role. Verify actual cluster ID, database, role and primary
   status before restoring.
5. Run the patched matching-major `pg_restore` as that role with
   `--no-password --no-owner --no-acl --single-transaction --exit-on-error`, the
   explicit isolated host/port/database/user and private `database.dump`. Require
   exit zero, then run the accepted readonly fixture's `verify` operation. It
   compares raw table fingerprints, schema/FKs/extensions/migrations and verifies
   each supported owned sequence's next allocation is within bounds and exceeds
   existing IDs without advancing it. Run the concurrent fixture's coherence
   verification on the restored database as a separate semantic check.
6. Remove temporary passfiles and plaintext after verification. Preserve any
   failed restore target for explicit inspection rather than automatically
   deleting it. Retain encrypted designated recovery copies for their approved
   window.

## Offline tooling checks

The ordinary CI job runs these dependency-free Ruby suites without deployment
secrets or access to a real database:

```sh
ruby test/deploy/release_artifacts_test.rb
ruby test/deploy/database_recovery_test.rb
ruby test/deploy/production_backup_test.rb
```

The production suite uses synthetic subprocess/storage fixtures. The separate
role, unit, deadline, concurrent-write and restore-check fixtures are explicitly
guarded operational rehearsals, not commands to run against production.

Primary references: [Spaces S3 compatibility](https://docs.digitalocean.com/products/spaces/reference/s3-compatibility/),
[Spaces versioning](https://docs.digitalocean.com/products/spaces/how-to/enable-versioning/),
[AWS CLI PutObject](https://docs.aws.amazon.com/cli/latest/reference/s3api/put-object.html),
[GetObject](https://docs.aws.amazon.com/cli/latest/reference/s3api/get-object.html),
and [HeadObject](https://docs.aws.amazon.com/cli/latest/reference/s3api/head-object.html).
