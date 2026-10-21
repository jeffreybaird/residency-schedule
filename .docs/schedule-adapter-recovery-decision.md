# Recovery decision — October 21, 2026

The owner canceled the old Phase 0 recovery program. This is a four-user family
app with infrequent data changes. The accepted fallback is to rebuild the server
and restore an available database snapshot, accepting downtime and changes lost
since that snapshot.

The old recovery plan is retired, not deferred or waiting for closeout. Its
checklists, handoffs, recovery-time/data-loss targets, backup activation,
additional storage and monitoring provisioning, PITR and formal recovery drills
are removed from the model migration scope. They are not development or release
gates and should not be resumed without a new request from the owner.

For a production data change, note the snapshot being relied on and the existing
[server setup/deployment instructions](../DEPLOY.md). This is a practical
snapshot-and-rebuild fallback, not a new recovery program or rehearsal requirement.
No snapshot availability or successful restore is asserted by this document.

Keep existing deployment locks, staging, retained artifacts, backup utilities and
tests. No services, timers, resources, subscriptions or credentials are changed
by retiring the plan. Operational records and utility instructions are reference
material, not outstanding work.

Ordinary correctness checks still apply: preserve identities, coverage links,
notes, simultaneous activities, overnight boundaries and import idempotency.
Production deployment remains a separate action on a reviewed implementation.

Continue the [model migration plan](schedule-adapter-release-plan.md): Phase 1 is
implemented locally; the next model work is Phase 2's additive schema.
