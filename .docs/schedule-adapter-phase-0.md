# Schedule adapter migration Phase 0 recovery readiness

Status: remaining work deferred by the owner on October 21, 2026; no longer a
gate to Phase 1 development. See the
[revised recovery decision](schedule-adapter-recovery-decision.md).
Recorded: October 15, 2026.
Parent: [Schedule adapter migration release plan](schedule-adapter-release-plan.md).
Progress and unresolved prerequisites: [Step 1 baseline](schedule-adapter-phase-0-baseline.md).

October 17 continuation: [PR #78](https://github.com/jeffreybaird/residency-schedule/pull/78)
is merged and its production/demo rollout is verified. The
[database recovery record](phase0-database-recovery.md) tracks Step 4 tooling
and isolated rehearsal. [PR #79](https://github.com/jeffreybaird/residency-schedule/pull/79)
is also merged, with its separately approved production/demo rollout verified.
The [production backup preparation record](phase0-production-backups.md) tracks
the next branch's scheduling, protected off-host storage and monitoring work;
those controls are not yet activated in production.
Unfinished database recovery objectives must not be inferred from the deployment
success; the checklist below records the original acceptance criteria.

The original acceptance checklist below is retained as historical scope. Unchecked
items are not claims of completion, and their old blocking language is superseded
by the October 21 decision. Keep delivered safeguards; do not activate new paid
resources, backup timers or alert integrations as part of Phase 1 development.

Phase 0 establishes the ability to deploy, validate and recover the application
before changing its schedule model. Deliver operational controls, tested scripts,
staging and evidence. Do not introduce the adapter schema or migrate production
schedule data in this phase.

## Step 1 Establish the baseline and recovery objectives

- [ ] Record the actual deployed SHA, database migration versions, database/server
  versions, service topology, existing backup facilities and deployment access.
  Refresh the code review against current `main`; the parent plan's reviewed
  commit is not evidence of the deployed version.
- [ ] Name the release operator, recovery operator and person making the go/no-go
  decision. One person may fill multiple roles, but responsibilities are explicit.
- [ ] Set the maximum acceptable recovery time (RTO), maximum acceptable lost
  writes (RPO), rollout window and artifact/backup retention period. Record values
  before live rollout; do not infer zero loss from the existence of a backup.
- [ ] Inventory all mutations: imports, builder saves, editor writes, coverage
  requests/approvals, resident identity changes and any direct operational jobs.
  Identify a proven way to stop all writes during disaster recovery.

Acceptance: a baseline/recovery record with concrete owners and objectives;
unknown operational facilities are explicitly unresolved, not assumed absent.

## Step 2 Create a persistent staging environment

- [ ] Use a separate database, service, credentials and endpoint. Staging must not
  point at production databases or invoke production integrations.
- [ ] Seed a persistent synthetic dataset covering multiple academic years,
  imported activities, coverage history, simultaneous tasks and overnight duty.
  Include the April vacation chain. Preserve data between deployments.
- [ ] Disable outbound email and assistant-provider calls or use test substitutes.
  Keep staging calendar feeds and tokens separate from production.
- [ ] Match production runtime/database versions and relevant proxy configuration.
  Add representative synthetic volume for latency and migration-lock rehearsals.
- [ ] Establish staging validation before production promotion. Preserve the
  existing demo independently; its automatic reseeding is unsuitable for this gate.

Acceptance: deploy twice and prove staging records persist and integrations remain
isolated. Prefer synthetic data. Any later production snapshot rehearsal requires
approved restricted handling and removal/replacement of tokens and credentials.

## Step 3 Retain immutable release artifacts and serialize deployment

- [ ] Build a versioned artifact once, identify it by commit and checksum, and
  promote the same tested bytes through staging and production.
- [ ] Keep build artifacts free of server `.env` files and runtime secrets. Keep
  environment configuration outside artifact retention or handle it separately
  with its existing private permissions.
- [ ] Retain the current and designated rollback artifacts for the entire rollback
  window. Replace deletion of the only previous release after startup with an
  explicit retention policy that never removes the designated recovery target.
- [ ] Serialize deployments per destination, including manual recovery commands.
  Do not cancel an in-progress migration/restart when a newer run arrives.
  Use run-specific staging paths to prevent `_new` directory collisions.
- [ ] Preserve `needs: test`, migration-before-restart ordering and the existing
  failure rollback path while improving it.

Acceptance: retrieve and verify a prior artifact after a successful later deploy;
two attempted deployments cannot mutate the same destination concurrently.

## Step 4 Prove backup coverage and restore a database

- [ ] Determine whether current recovery uses logical dumps, snapshots or
  point-in-time recovery. Verify retention, encryption, off-host storage, access
  and monitoring without printing credentials or resident data.
- [ ] Record what the backup covers: schedule tables, people/memberships, activities
  and provenance, notes, coverage/change requests, users/auth data, migration state
  and required database roles/extensions. Inventory private mapping/configuration
  files separately; do not assume a database backup contains them.
- [ ] Restore into a disposable isolated database and run the current release
  against it. Never test restoration by overwriting production.
- [ ] Check identities, foreign-key integrity, notes, coverage, activity provenance
  and semantic schedule results. Measure restoration and verification duration.
- [ ] If zero/near-zero write loss is required, prove the available WAL/PITR or
  replay mechanism. An ordinary dump does not capture later writes. Document the
  recovery point and any unrecoverable interval.

Acceptance: a successful restore report meeting Step 1 objectives. Failed or
unverified recovery blocks later migration work from reaching production.

## Step 5 Add release and schedule smoke checks

- [ ] Verify the running artifact identity, application/database readiness and
  expected schema version. Check an authenticated schedule page and a LiveView
  interaction, not only unauthenticated `/` reachability.
- [ ] Check resident timelines, calendar/day views, coverage, notes, statistics
  and calendar exports against the synthetic reference dataset.
- [ ] Exercise CSV and QGenda preview/commit, reimport and an editor change in
  staging. Do not run synthetic writes against production for health checks.
- [ ] Define production checks as read-only and avoid exposing private schedule
  content or tokens in CI logs. Limit monitoring to permitted aggregate data.
- [ ] Establish repeatable performance baselines and numeric thresholds for error
  rates, latency and lock waits before using them as rollout gates.
- [ ] Verify current protocol mitigation and ordinary security checks; follow the
  live Bandit patch procedure rather than relying on its historical baseline.

Acceptance: checks fail for a wrong release, database failure and deliberately
incorrect synthetic schedule result, and pass for the verified baseline.

## Step 6 Implement and rehearse application rollback

- [ ] Provide a documented release command/script that selects a retained artifact,
  verifies its checksum and schema compatibility, excludes concurrent deployment,
  restores the application, and checks the recovered release.
- [ ] Keep runtime configuration compatible with the rollback artifact. Do not
  archive production secrets inside ordinary build artifacts.
- [ ] Trigger startup failure in staging and verify automatic recovery. Separately
  rehearse operator rollback after startup succeeded but a semantic check failed.
- [ ] Preserve the failed artifact and bounded diagnostic evidence. If recovery
  health checks fail, leave the service in a controlled state and escalate; do not
  report successful rollback or repeatedly swap versions automatically.
- [ ] Measure recovery time and verify records created before rollback remain
  intact. Do not automatically run down-migrations.

Acceptance: both failure scenarios recover the expected application within the
recorded objective, with verified data and a reproducible recovery command.

## Step 7 Prove the migration compatibility procedure

- [ ] In a disposable staging database, apply a representative additive migration
  while the old application is active. Use an isolated rehearsal fixture, not a
  dummy migration deployed to production.
- [ ] Exercise the old application against the expanded schema, deploy the new
  application, and roll back its binary while retaining the expanded schema.
- [ ] Rehearse migration failure and interrupted-deploy behavior. Confirm the old
  application remains usable or the maintenance/recovery procedure is effective.
- [ ] Measure locks and duration with representative volume. Set execution bounds
  and abort criteria; separate large backfills from startup migrations.
- [ ] Require the same compatibility test for every actual Phase 2 migration.
  A representative drill does not prove future migrations safe.

Acceptance: documented compatibility and failure evidence. No destructive schema
operation is included in this rollout path.

## Step 8 Rehearse disaster recovery and write protection

- [ ] Prove the mechanism that prevents all mutations during recovery. Full service
  maintenance is acceptable initially if a comprehensive read-only mode does not
  exist. Blocking the upload form alone is insufficient.
- [ ] In staging, make known synthetic changes before and after a recovery point,
  simulate a bad data change, then restore and replay using the actual supported
  recovery method.
- [ ] Reconcile recovered assignments, later legitimate changes, coverage links,
  notes and identities. Invalidate stale cache/session-derived state as needed.
- [ ] If later writes cannot be replayed, quantify the loss and record that limit;
  do not reopen writes until the recovered state has been validated.
- [ ] Measure end-to-end recovery time including verification. Keep this evidence
  distinct from the quicker application rollback drill.

Acceptance: recovery meets agreed RTO/RPO, or objectives/capabilities are explicitly
revised before rollout. No claim of lossless recovery without demonstrated replay.

## Step 9 Package changes into reviewable deliveries

Implement in dependency order; every behavior change follows the repository's
[test and independent-review workflow](agent-workflow.md).

| Delivery | Scope | Required evidence |
| --- | --- | --- |
| Step 1 PR | Baseline, mutation inventory, objectives and access gaps | Repository evidence distinguished from live observations. |
| Step 2 PR | Persistent staging setup and synthetic fixture | Isolation and two-deployment persistence checks. |
| Step 3 PR | Artifact retention and deployment serialization | Retrieval/checksum test and concurrent-deployment rehearsal. |
| Step 4 PR | Backup verification and isolated restore procedure | Successful restore and measured recovery point/duration. |
| Step 5 PR | Release and schedule smoke-check tooling | Semantic checks and performance thresholds. |
| Step 6 PR | Application rollback tooling and rehearsal | Startup and semantic failure recovery. |
| Step 7 PR | Additive-schema compatibility rehearsal | Old/new application compatibility and migration failure evidence. |
| Step 8 PR | Disaster recovery and write protection rehearsal | Measured recovery with explicit data-loss bounds. |
| Step 10 PR | Release record and Phase 0 closeout | Independent review of the complete exit checklist. |

Use one PR per step where practical, as requested. A step may have a tooling PR
followed by an evidence update when infrastructure access becomes available.
Repository-only safeguards such as Step 3 may be prepared while Step 2 access is
unresolved; this does not bypass staging or recovery gates for deployment.

Keep production deployment as a separately authorized action on a concrete tested
result. Every commit, including documentation commits, follows the current
[Bandit exception procedure](bandit-http2-audit-exception.md) and project checks.

## Step 10 Close Phase 0 before enabling Phase 1

- [ ] Staging is persistent, isolated and exercised with representative data.
- [ ] One tested artifact is promotable; prior compatible artifacts are retrievable.
- [ ] Concurrent deploy/recovery operations cannot collide.
- [ ] Backups restore successfully; recovery objectives are met and measured.
- [ ] Application rollback works after startup failure and semantic failure.
- [ ] Additive-schema compatibility and migration failure have been rehearsed.
- [ ] Schedule-specific smoke checks and performance thresholds are recorded.
- [ ] The release record names owners, exact artifacts, schema versions, commands,
  backup/recovery evidence, unresolved issues and the go/no-go decision.
- [ ] A reviewer confirms no unresolved blocker is being treated as a completed
  prerequisite. Production has no adapter-model changes from Phase 0.

Store reusable instructions and sanitized evidence in repository documentation.
Keep backup locations requiring privileged access, private operational details
and resident-level comparison evidence in the designated restricted system;
reference them without copying their contents into Git.
