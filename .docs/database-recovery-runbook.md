# Synthetic database backup and isolated restore

Status: implementation independently accepted; exact-tool operational rehearsal
is recorded separately in the recovery record.
This work continues Phase 0 Step 4 from merged PR #78. It does not change the
production schedule schema or install a production backup service.

## Boundaries

Use only trusted operator-generated synthetic data on the separately approved
staging PostgreSQL cluster. A backup is an executable database program when
restored. GPG encryption and checksums protect confidentiality and detect
corruption; without a signature they do not establish who produced a backup.
Keep the generated bundle and transfer channel restricted to the release operator.

The production/demo databases and original persistent staging database are never
restore destinations. Restore into a new disposable database with a new restricted
login role. No existing database or role is dropped or overwritten. The generated
role has no superuser, role/database creation or replication privileges; connect
`pg_restore` directly as that role, rather than using an administrator connection
with `SET ROLE`. The latter could regain administrator privilege from SQL in the
archive.

## Intended workflow

1. Prepare private configuration with exact staging cluster/source guards and an
   operator GPG public recipient. Use a disposable synthetic source enriched with
   nonempty representative notes, approved coverage history and authentication/feed
   records. Keep the active persistent staging baseline unchanged.
2. Freeze writes to the disposable source. Record the assertion and its limits.
   Export a PostgreSQL snapshot and use that same held snapshot for the dump and
   table verification baseline. Sequence values are not MVCC state: the exported
   snapshot does not replace the write freeze for exact sequence comparison.
3. Produce a custom-format logical dump and private coverage manifest, encrypt
   them, and remove temporary plaintext. Record snapshot time, completion time and
   ciphertext checksums. All supported application objects must be covered;
   reject unsupported scope explicitly instead of silently excluding it.
4. Copy the encrypted bundle off-host using the existing authenticated SSH path.
   Retain the designated copy; verify its checksums independently.
5. Decrypt in a fresh private operator directory. Keep the private GPG key off the
   database host. Verify encrypted integrity and the manifest's plaintext dump
   digest before transferring only the protected synthetic plaintext inputs to the
   isolated restore host. Remove temporary plaintext when verification is complete.
6. Restore to the exact new disposable database and role after actual server and
   cluster identity checks. Fail on SQL errors. Retain explicit failure state for
   inspection rather than deleting arbitrary existing objects during cleanup.
7. Compare the restored contents, identities, sequences, constraints, extensions
   and migration state with the baseline. Run the current immutable release
   against only that disposable database on a distinct loopback service/node,
   with real email/assistant/telemetry disabled. Check authenticated schedule and
   representative semantic results.
8. Record total recovery and verification duration and the actual recovery point.
   A single logical dump contains no writes made after its snapshot. A freshness
   status check is an operator check, not an installed schedule or alert service.

## Security and recovery limits

Do not put database URLs/passwords, private keys, raw diagnostics, rows, feed
credentials or resident identifiers in command arguments, CI logs or Git. Private
configuration and decrypted files use mode 600 in mode-700 directories. Use only
the current patched PostgreSQL 16.15 client tools on staging for this rehearsal;
the workstation PostgreSQL 17.10 client is behind the 17.11 security fixes and is
outside this tool path.

This rehearsal cannot establish production backup coverage or the 15-minute RPO.
Production storage/retention/encryption-key recovery, scheduling/failure alerts,
verified write freeze, production restricted restore handling and WAL/PITR remain
explicit follow-up decisions and evidence. Do not mark Phase 0 Step 4 complete
until the actual production recovery objectives are demonstrated.

Primary references: [PostgreSQL 16 pg_dump](https://www.postgresql.org/docs/16/app-pgdump.html),
[PostgreSQL snapshot synchronization](https://www.postgresql.org/docs/16/functions-admin.html#FUNCTIONS-SNAPSHOT-SYNCHRONIZATION),
and [GnuPG operational commands](https://www.gnupg.org/documentation/manuals/gnupg/Operational-GPG-Commands.html).

## CLI and private configuration

The CLI is:

```text
ruby deploy/database_recovery.rb backup CONFIG.json NEW_ENCRYPTED_DIRECTORY
ruby deploy/database_recovery.rb status CONFIG.json ENCRYPTED_DIRECTORY
ruby deploy/database_recovery.rb decrypt CONFIG.json ENCRYPTED_DIRECTORY NEW_PRIVATE_DIRECTORY
ruby deploy/database_recovery.rb restore CONFIG.json PRIVATE_DIRECTORY
ruby deploy/database_recovery.rb verify CONFIG.json PRIVATE_DIRECTORY
```

Database commands use a mode-600 JSON configuration containing `schema_version`
(1), exact `source_database`, `expected_cluster_identifier`, local socket
`pg_host`, numeric `pg_port`, `pg_user`, `write_freeze_asserted` and
`max_age_seconds`. Backup adds a private public-key-only `gpg_home` and full
`gpg_recipient` fingerprint. Decrypt needs only the version and operator's private
GPG home. Restore/verify add exact `recovery_database`, `recovery_role`,
`recovery_password`, and loopback `recovery_host`.

Run database commands as the OS user matching the configured local PostgreSQL
administrator (on staging, `sudo -u postgres ruby ...`), from a private directory
owned by that user. This preserves local peer authentication without adding sudo
hooks to the CLI. `pg_restore` connects over loopback directly as the restricted
recovery role using a temporary private passfile; the administrative connection
creates only the new role/database and does not execute the archive.

The encrypted directory contains exactly `database.dump.gpg`,
`manifest.json.gpg` and `backup.json`. The decrypted directory contains exactly
`database.dump` and `manifest.json`. The manifest pairs the plaintext dump digest
with the source identity, recovery point and verification inventory. Public
metadata exposes only bounded recovery timing, source name and ciphertext
checksums; detailed coverage/role information stays encrypted.

## Verification fidelity

The supported application scope is ordinary tables in all user schemas, full row
contents, sequence state and definition/ownership, extension name/version/schema,
columns and defaults, constraints and indexes, functions, triggers (including
whether enabled), views and enums. Source-role attributes are inventoried without
passwords; the recovery owner intentionally differs. Original owners/ACLs are not
replayed. This is not a claim of universal equivalence for every possible
PostgreSQL object class. Known unsupported classes listed by the inventory query
are rejected. Acceptance is limited to the inspected application schema and the
enumerated classes; new object classes require review before use.

Restore requires trusted administrative access to the local socket and then
checks the TCP connection as the new restricted role against the expected actual
cluster identifier. A narrow `EXECUTE` grant for `pg_catalog.pg_control_system()`
in only the new disposable database permits that identity check. No broad
monitoring or server-settings role is granted.

Password-bearing role creation uses SQL stdin after disabling statement, error
statement, duration and sampled statement logging in that session. This does not
control arbitrary external/audit extensions. The release operator must inspect
server/audit logging beforehand and keep database logs restricted. No private
configuration values are printed by the CLI.
