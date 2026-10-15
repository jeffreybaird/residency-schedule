# Phase 0 release artifacts and deployment serialization

This implements the bounded Step 3 controls described in the
[Phase 0 baseline PR](https://github.com/jeffreybaird/residency-schedule/pull/77).
It does not establish persistent staging, demonstrated recovery objectives,
database restore capability, semantic smoke checks, or a rehearsed operator
rollback. Accepted ownership and recovery targets are recorded in that baseline
PR; operational validation remains a separate Phase 0 prerequisite.

## Build once and promote

The deployment workflow requires its test job, builds one Mix release, and
packages `release-<commit>.tar.gz` with `release-<commit>.sha256`. The package
contains a `RELEASE_ID` identifying the source commit. Production and demo
download the same uploaded artifact; neither deployment job rebuilds it.
Existing demo-only seeding remains separate from production.

Build jobs receive no server `.env`, `SECRET_KEY_BASE`, provider token or other
runtime deployment secret. The release packager excludes Mix's generated
`releases/COOKIE` distribution credential. Package and legacy snapshot capture
allowlist the code directories `bin`, `erts-*`, `lib`, and `releases`; runtime
`tmp`, crash dumps, root configuration backups, `.env` files and distribution
cookies are not retained as code artifacts. The package validator rejects
unsafe archive paths, links and special files before extraction. An archive
checksum establishes byte integrity, not a signature or independent provenance;
the existing trusted workflow and SSH transport remain the delivery boundary.

The artifact uploaded by a build is immutable for that workflow run. Host
retention stores verified archives and checksums in `<INSTALL_DIR>.artifacts`,
identified by both commit and content digest. Installed `ARTIFACT_ID` records
that exact retained archive; `RELEASE_ID` continues to record the source commit.
Rebuilding a commit can produce different bytes, so the commit alone is not an
artifact identity. An identical identity cannot silently replace different data.
The first upgraded deployment captures the existing code as a sanitized legacy
artifact because an original build archive may not exist. A legacy capture is
not evidence of reproducibility or of the originally deployed build checksum.

## Runtime configuration and private temporary state

Existing systemd paths and `<INSTALL_DIR>/.env` stay in place. A candidate gets
a private mode-600 configuration copy; nonempty optional GitHub settings update
that copy. The current configuration is not changed if validation or migration
fails. Existing `releases/COOKIE`, when present, is copied privately to the
candidate with mode 600. A nonempty effective `RELEASE_COOKIE` from the trusted
server environment remains supported and retains precedence. The deployment
never generates or rotates the distribution cookie; missing both sources fails
closed before running the migration or restarting the service.

Temporary candidate and rollback trees live under a mode-700 deployment work
directory. They can contain runtime configuration and cookies during promotion;
they are not ordinary retained build artifacts. After successful startup or
verified recovery, temporary secret copies are removed. If recovery fails, keep
the protected recovery state for an operator; do not delete the last recoverable
copy or publish it as an artifact. Do not print environment contents, cookies,
raw application logs, database output or resident data into CI diagnostics.

The host needs Bash, Python 3.8 or newer, `flock`, checksum/tar utilities, `curl`, and the
existing permitted systemd commands. Local tests verify behavior with synthetic
files and stubbed services; they do not verify those facilities on the droplet.

## Serialization and retention

Workflow concurrency is scoped per destination with `cancel-in-progress: false`.
Incoming transfer paths include the run identity and attempt. The host uses the
stable `<INSTALL_DIR>.deploy.lock` outside the swapped application directory;
it covers configuration, migration, directory swaps, restart and health checks.
The parent promotion process retains the lock; release subprocesses close the
lock descriptor so a BEAM helper or daemon cannot retain it after promotion ends.
Production and demo have independent locks because their install paths differ.

Every manual deployment or recovery procedure must acquire that same host lock.
The lock must already be initialized by, and remain writable by, the `deploy`
user. Root maintenance recipes must not create a new root-owned lock file; the
examples require the existing file. Do not replace or unlink a lock file while
an operation may hold it, because that would create a different lock inode.
For an existing production install, an operator can enter a locked maintenance
shell with:

```sh
flock -x --close /home/deploy/residency_schedule.deploy.lock bash
```

The future rollback command must use this lock too. Do not use the former
unguarded `_old` directory swap recipe. Step 6 still needs a checksum-verified,
schema-compatible operator rollback command and its rehearsal.

There is **no automatic host artifact pruning** in this step: preserve all
archives until owners approve the rollback window and a retention policy that
protects the designated recovery target. Monitor disk capacity before rollout.
GitHub artifact availability also depends on repository retention settings; it
does not replace the retained host copy. No approved rollback window is inferred
from GitHub's default retention.

## Failure and recovery boundaries

Validate the incoming checksum, release identity and archive contents before
sourcing configuration or running application/service commands. Capture the
prior code artifact before the first mutation. Migrations run from the candidate
before swapping directories and restarting. Migration failure leaves the current
application files and process in place; it does not trigger an unnecessary
restart. Demo seeding can change data and is not reversible through binary swaps.

Failures during the directory swap, restart or startup HTTP check attempt to
restore the previous application and verify its HTTP readiness. Recovery failure
is reported separately and remains a failed deployment. Prior and failed code
artifacts remain available. The HTTP check is a startup check, not schema,
schedule-meaning, authentication or LiveView acceptance evidence.

Binary rollback does not undo migrations or restore database writes. Abrupt
power loss or `SIGKILL` can bypass shell traps; an operator must inspect the
protected work directory and retained artifacts under the same lock. Additive
schema compatibility and disaster recovery remain later Phase 0 gates.

Before every commit, retain the existing
[fresh Bandit patch-check procedure](bandit-http2-audit-exception.md). The
temporary advisory exception does not permit other security findings or an
unverified check. No production deployment is authorized by this documentation.
