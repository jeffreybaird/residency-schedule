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
contains a `RELEASE_ID` identifying the source commit. Staging, production and
demo download the same uploaded artifact; no deployment job rebuilds it.
Staging must succeed before production/demo can run. Only a push to `main` runs
production/demo. Candidate branch pushes and manual dispatch rehearse staging
alone; the exact candidate branch is enabled explicitly so rehearsal works
before the dispatcher reaches the default branch.
Existing demo-only seeding remains separate from production.

Production and demo promote automatically once staging passes; neither GitHub
environment carries a required-reviewer gate. The `prod` gate used for the
initial PR #78 rollout was removed on 2026-10-20: approval was only available
from a desktop browser, and because each deployment job holds the
`deploy-<target>` concurrency group, an unapproved production job did not
simply wait; GitHub cancelled every later push's production job behind it while
demo kept deploying, so `main` silently stopped reaching production. Do not
reintroduce a required reviewer on `prod` or `demo` without also handling that
queue behaviour. Branch restrictions on the environments remain the control
that keeps candidate branches off production and demo.

Build jobs receive no server `.env`, `SECRET_KEY_BASE`, provider token or other
runtime deployment secret. The release packager excludes Mix's generated
`releases/COOKIE` distribution credential. Package and legacy snapshot capture
allowlist the code directories `bin`, `erts-*`, `lib`, and `releases`; runtime
`tmp`, crash dumps, root configuration backups, `.env` files and distribution
cookies are not retained as code artifacts. The package validator rejects
unsafe archive paths, links and special files before extraction. An archive
checksum establishes byte integrity, not a signature or independent provenance;
the existing trusted workflow and SSH transport remain the delivery boundary.

Archives use the supported USTAR format. The Ruby validator rejects PAX/GNU
metadata extensions rather than guessing their effect on entry paths or types.
An archive produced by the earlier Python draft can contain such extensions;
it is not automatically accepted or converted. Validation must fail before
configuration, migrations or service changes if an existing archive is outside
the supported format. Inspect and repackage trusted original code separately
rather than bypassing validation. No live use of the earlier draft is established.

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

GitHub Environments `prod`, `demo` and `staging` are the source of truth. The deployment
job binds its environment from the fixed target matrix. Only the render step
receives runtime secrets through step environment bindings; build/test jobs
and SSH command bodies do not receive them. The public `PHX_HOST` and required
`CONFIG_ENVIRONMENT` marker come from environment variables, while the separate
`DEPLOY_TARGET` comes from the trusted target matrix. Missing or mismatched
markers fail validation. GitHub can fall back to repository-level secrets:
configure every target explicitly, including a distinct database and credentials.
`EXPECTED_DATABASE_NAME` must match the URL database, but this guard is not proof
of database privileges or demo isolation.

The Ruby renderer selects allowlisted, nonempty step bindings, rejects control
characters and a mismatched supplied target marker, and writes JSON into a private
workspace directory (mode 700, file 600). A target and database-name preflight
rejects missing or mismatched bindings before that private payload is written or
transferred. Required and conditional settings receive full schema validation
and default normalization again on the host before any active release change;
CI filtering and preflight are not full host schema validation.
A separate SCP uploads only that file;
its destination and transport-tar directory are prepared with mode 700. It never
enters the uploaded code artifact. Both local and remote incoming payloads have
always-run cleanup steps, including transfer-failure paths. Network or runner
loss can still require removal of a protected residual inbox; never publish its
contents as diagnostics. The SCP action uses workspace-relative paths because
its Docker mount does not expose arbitrary runner temporary directories.

Under the existing host lock, promotion validates the entire configuration and
code archive before altering the active installation. It creates
`<INSTALL_DIR>.config/<version>/runtime.json` and `runtime.env`, with directory
mode 700 and files 600, and records the associated code/release identity in
`deployment.json`. The candidate `.env` is an absolute compatibility symlink to
that version's managed `runtime.env`. Existing systemd `EnvironmentFile` paths
stay unchanged; swapping or restoring the release selects its matching config.
A managed symlink must resolve inside the expected private version layout, with
a regular canonical JSON sidecar and exactly matching generated environment file.

This is a complete replacement, not a merge of the previous `.env`. Disabling
features or removing optional settings clears their old credentials/settings.
Migration subprocesses receive the validated JSON values directly, with absent
managed variables explicitly removed from their inherited environment. The
environment-file encoding is for systemd, not for shell evaluation: do not source
the generated file. Quotes, backslashes, dollars and backticks remain literal;
Control characters, including NUL, CR and LF, are rejected. Check existing systemd
units, drop-ins and wrappers for competing `Environment=` settings and additional
`EnvironmentFile=` inputs before rollout. An omitted optional key cannot erase an
unrelated unit-level value; those overrides must not remain a competing source of
managed settings. Perform that inspection without printing secret values.

On the first transition, the installed legacy `.env` may be a regular private
file. Its exact bytes and any cookie file are retained separately under a private
`legacy-<version>` configuration folder, associated with the retained prior code
artifact. Cookie inspection parses only supported literal assignments; it never
executes or sources legacy configuration. Unsupported forms require an explicit
migration to literal settings. GitHub's required `RELEASE_COOKIE` must equal the
previous effective cookie (a managed JSON value, a supported legacy override, or
the existing cookie file). Missing continuity evidence or a changed cookie fails
closed; the deployment does not generate or silently rotate cookies. Existing
`releases/COOKIE`, if present, remains a private mode-600 compatibility copy.
Import the existing `SECRET_KEY_BASE` into the matching GitHub environment before
the first transition to preserve signed sessions. That is an operator requirement;
the automatic continuity check compares the release cookie, not the signing key.

Keep all managed and legacy configuration versions private and retain the
designated recovery versions until an approved retention policy says otherwise.
They contain secrets even though the code archives do not. Failure recovery
restores the previous release and its matching config; preserving these versions
does not implement the later checksum/schema-compatible operator rollback tool.

### Configuration schema

Only the following input keys are accepted. GitHub bindings are limited to the
render step; host context such as `DEPLOY_TARGET`, `APP_PORT`, install paths and
run identity is supplied separately from the fixed deployment matrix.

| Key | Source and requirement | Default or constraint |
| --- | --- | --- |
| `CONFIG_ENVIRONMENT` | Environment variable, required | Exactly `prod`, `demo` or `staging`, matching independent `DEPLOY_TARGET`; propagated to release processes and systemd. |
| `EXPECTED_DATABASE_NAME` | Environment variable, required | Must match the decoded database path in `DATABASE_URL`. |
| `DATABASE_URL` | Environment secret, required | Plain `postgres`, `postgresql` or `ecto` URL; query options and fragments are rejected. |
| `SECRET_KEY_BASE` | Environment secret, required | At least 64 bytes; keep prod/demo signing secrets distinct. |
| `PHX_HOST` | Environment variable, required | Hostname only, without URL scheme, path or credentials. |
| `ACCESS_PASSWORD` | Production/staging secret | Required for authenticated production and staging; omit it for demo. |
| `RESEND_API_KEY` | Production secret | Required for production; rejected for demo/staging. Staging uses the in-memory Swoosh test adapter. |
| `RELEASE_COOKIE` | Environment secret, required | Must preserve the previous effective cookie; never generated or silently rotated. |
| `PORT` | Target-derived setting | The workflow supplies the matrix port; direct JSON values must match `APP_PORT`, and omission uses that port. |
| `HTTP_IP` | Environment variable, optional | IPv4 bind address; defaults to `127.0.0.1`. |
| `POOL_SIZE` | Environment variable, optional | Positive integer; defaults to `10`. |
| `DB_SSL` | Environment variable, optional | `true` or `false`; defaults to `false`. |
| `ROSTER_PATH` | Environment variable, optional | Explicit roster path when required; omission removes the previous override. |
| `CHAT_ENABLED` | Environment variable, optional | Defaults to `false`; demo/staging cannot enable the provider integration. |
| `ANTHROPIC_API_KEY` | Conditional environment secret | Required when production chat is enabled; omitted from active config when disabled. |
| `OTEL_ENABLED` | Environment variable, optional | Defaults to `false`; demo/staging cannot enable telemetry export. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | Conditional environment variable | Required HTTPS collector URL when telemetry is enabled; no credentials/query/fragment. |
| `OTEL_HUB_TOKEN` | Conditional environment secret | Required when telemetry is enabled; omitted when disabled. |
| `OTEL_RESOURCE_ATTRIBUTES` | Environment variable, optional | Administrative attributes only when telemetry is enabled; never include resident data or secrets. |
| `DEMO_MODE` | Target-derived setting | `false` for prod/staging, `true` for demo; conflicting supplied values are rejected. |
| `PHX_SERVER` | Target-derived setting | Always `true`. |
| `RELEASE_NODE` | Target-derived setting | `residency_schedule@127.0.0.1` for prod; `residency_schedule_demo@127.0.0.1` for demo; `residency_schedule_staging@127.0.0.1` for staging. |
| `RELEASE_DISTRIBUTION` | Target-derived setting | Always `name`; arbitrary release path/runtime overrides are not accepted. |

Do not silently remove database URL query settings to make validation pass.
Use the explicit supported `DB_SSL` setting where appropriate; advanced SSL or
other connection options require review rather than an implicit translation.
Database guards still require an operational check of roles and distinct target
credentials before rollout.

Staging uses `STAGING_DEPLOY_HOST`, installation/service
`residency_schedule_staging`, and loopback port 4004. It has its own database,
credentials, signing key and cookie. It never runs the demo reset-on-deploy seed.
Provision an initial isolated installation before promotion; promotion does not
bootstrap an empty host. Live observations and unresolved rollout gates are in
[the local rollout record](phase0-local-rollout-record.md).

Temporary candidate and rollback trees live under a mode-700 deployment work
directory. They can contain runtime configuration and cookies during promotion;
they are not ordinary retained build artifacts. After successful startup or
verified recovery, temporary secret copies are removed. If recovery fails, keep
the protected recovery state for an operator; do not delete the last recoverable
copy or publish it as an artifact. Do not print environment contents, cookies,
raw application logs, database output or resident data into CI diagnostics.

The requester accepted Ruby deployment tooling. The host needs Bash, Ruby 3.3
(tested with Ruby 3.3.8 and its standard-library RubyGems archive support),
`flock`, checksum/tar utilities, `curl`, and the existing permitted systemd
commands. Deployment requires no Python interpreter or application boot to
validate artifacts. The test suite uses Minitest 5.x (locally tested with 5.25.4);
it is a development/CI requirement, not a host deployment dependency. CI selects
the maintained Ruby 3.3 patch release. Local tests verify behavior with synthetic
files and stubbed services; they do not verify Ruby or the other host facilities
on the droplet.

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

Validate the incoming configuration, checksum, release identity and archive
contents before running application/service commands. Capture the
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

Run current security checks before every commit under the shared workflow. The
former Bandit audit exception has expired following the published 1.13.0 fix;
see [upgrade verification](bandit-1.13-upgrade-verification.md). No production
deployment is authorized by this documentation.
