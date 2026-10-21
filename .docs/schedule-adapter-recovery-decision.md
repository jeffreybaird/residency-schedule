# Recovery scope decision — October 21, 2026

The owner revised the recovery requirements while authorizing continuation of
the residency scheduler model/adapter work. This app serves four family members,
and its data changes infrequently. The owner accepts rebuilding the server and
restoring a database snapshot if recovery is needed, including the associated
downtime and loss of changes since that snapshot.

This decision supersedes the recovery prerequisites in the October 15 release
plan, Phase 0 checklist and earlier handoffs. It does not assert that any snapshot
exists or has been verified, or that unfinished Phase 0 work was completed.

## What changes

- Proceed with Phase 1: shared import contract, parser adapters, preview
  orchestration and builder domain input, preserving existing persistence and
  rendering. New adapters remain preview-only until deliberately enabled.
- Defer production backup activation, additional storage/monitor provisioning,
  PITR, formal recovery drills and the 10-minute application / 60-minute database
  recovery and 15-minute lost-write objectives as prerequisites to development.
- Keep existing deployment locks, retained artifacts, staging, backup tooling and
  tests. This decision does not remove infrastructure, alter an active timer or
  change an existing paid subscription.
- Before a production data/schema change, identify the snapshot to recover from
  and the existing server rebuild/deployment instructions. Do not claim verified
  recovery or silently assume an application rollback restores the database.
- Keep ordinary correctness checks: preserve stable identities, coverage links,
  notes, simultaneous activities, overnight boundaries and import idempotency.
  Test changes through the repository's role-owned workflow.

Production deployment remains a separate action on a concrete reviewed change;
this decision authorizes development, not a deployment or production migration.

## Next delivery

Implement the Phase 1 adapter boundary without schema migrations. Split the work
into complete tested increments, and record any remaining Phase 1 scope honestly.
The later additive schema and read/write transition remain separate deliveries.
