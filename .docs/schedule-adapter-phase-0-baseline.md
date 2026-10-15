# Phase 0 Step 1 baseline and recovery requirements

Status: repository inventory complete; operational acceptance pending.
Recorded: October 15, 2026.
Parent: [Phase 0 runbook](schedule-adapter-phase-0.md).

This record starts Phase 0 and tracks evidence needed before infrastructure
changes are deployed. It does not certify production recovery readiness.

## Verified repository baseline

`origin/main` was refreshed on October 15, 2026 and points to
`79e35115db5149746b5e47d0f6345542e755c361`, merging PR #76's adjacent vacation
fix. This is a source baseline, not a verified deployed SHA.

| Item | Repository evidence | Operational status |
| --- | --- | --- |
| Deploy trigger | Push to `main`; deployment requires the test job. | Actual most recent successful production run not verified. |
| Build runtime | Elixir 1.19.5 and OTP 28.5.0.7 in CI/deployment workflows. | Installed/running production versions not verified. |
| Database | CI uses PostgreSQL 16. | Production server version, topology and replication not verified. |
| Schema | Latest checked-in migration is `20261013143545_add_schedule_cache_revision`. | Applied production migration versions not queried. |
| Production app | Workflow names service `residency_schedule`, port 4000, install path `/home/deploy/residency_schedule`. | Service unit and running process not inspected. |
| Demo app | Workflow names service `residency_schedule_demo`, port 4002; seeds synthetic data every deploy. | Not a persistent rehearsal environment. |
| Proxy/listener | Runtime defaults to loopback; code describes same-host Nginx; Bandit HTTP/2 disabled. | Actual listener and proxy settings not inspected. |
| Release identity | Workflow packages `priv/deploy_sha`. | Installed file not read from the host. |
| Rollback | Application directory swap on startup HTTP failure, after database migrations; previous directory removed after successful startup. | No database restore or post-start semantic recovery proven. |
| Backups | No backup/restore provisioning found in the reviewed deployment path. | Existing external facilities may exist; retention, restore and PITR are unknown. |
| Staging | Existing workflow contains production and reset-on-deploy demo targets. | No persistent staging destination supplied in this session. |

Sources: [deployment](../.github/workflows/deploy.yml),
[CI](../.github/workflows/ci.yml), [runtime configuration](../config/runtime.exs),
[release operations](../lib/residency_schedule/release.ex),
[migration files](../priv/repo/migrations).

The managed environment reports no configured secrets, outbound identities or
VPN access. Git fetch/push and the GitHub connector are available. A read-only
attempt to inspect push-triggered Actions runs using `gh api` returned Forbidden;
the available commit-workflow connector is restricted to pull-request runs.
Neither result proves production deployment state. No production connection or
database access has been attempted using guessed credentials or destinations.

## Owners and proposed objectives

The requester has been asked to confirm owners, recovery objectives and an
existing connection/profile or setup location. These values are proposals until
confirmed; elapsed time is not acceptance.

| Decision | Proposed starting point | Acceptance state |
| --- | --- | --- |
| Release/recovery/go-no-go owner | Requester, with delegation recorded if needed | Pending confirmation |
| Application rollback RTO | At most 10 minutes, including health verification | Pending confirmation and rehearsal |
| Database recovery RTO | At most 60 minutes, including reconciliation | Pending confirmation and rehearsal |
| Database RPO | At most 15 minutes of lost writes | Pending confirmation and demonstrated backup/replay capability |
| Rollout window | Low-activity window with recovery operator available | Time and operator pending |
| Retention | Preserve designated rollback artifacts throughout the rollback window; never automatically prune them | Duration and backup retention pending |

The RPO proposal is not a promise that current infrastructure can meet it.
Backups and restored/replayed records must demonstrate the actual limit.

## Mutation inventory and recovery freeze boundary

| Mutation family | Entry points and owning contexts | Recovery consideration |
| --- | --- | --- |
| Annual CSV and dated updates | Upload LiveView; `ScheduleImporter`, `DateUpdater` | Writes memberships/rotations and affects referenced schedule state. |
| QGenda detail | Upload LiveView; `DetailedSchedules.commit/2` | Writes batches, activities, provenance and notes. |
| Builder/editor | Builder and editor LiveViews; `ScheduleBuilder.save/1`, `ScheduleEditor.commit/2` | Existing browser sessions can still submit changes. |
| Coverage requests and overrides | Resident/admin interactions, assistant tool and MCP; `ChangeRequests`, `ShiftOverrides` | Requests, approvals, denials, cancellations and direct override operations must stop; coverage can span schedules. |
| People and roster maintenance | `Residents`, `Schedules` and imports | Renames, memberships, orphan cleanup and schedule deletion affect identity and references. |
| User/authentication state | Auth/admin controllers and LiveViews; `Accounts` | Login tokens, passwords, roles, approvals, home-resident links and tour preferences write to the database. |
| OAuth | OAuth endpoints and `OAuth` context | Client registration, authorization codes, token issuance/refresh/revocation and cleanup can write independently of schedule uploads. |
| Assistant sessions and quotas | Chat session/store/quota modules | Conversation persistence, quotas and approved coverage tools can write. |
| Operational writers | Release migration/admin/bootstrap/demo-seed commands, direct SQL and operator jobs | Separate from web request controls; inventory host cron/timers and all external clients. |
| Cache revision | Database triggers on schedule-related tables | Restored data and cached projections must be reconciled before reopening traffic. |

Sources: [router](../lib/residency_schedule_web/router.ex),
[accounts](../lib/residency_schedule/accounts/accounts.ex),
[OAuth](../lib/residency_schedule/oauth/oauth.ex),
[coverage](../lib/residency_schedule/change_requests/change_requests.ex),
[assistant](../lib/residency_schedule/assistant/assistant.ex),
[chat store](../lib/residency_schedule/assistant/chat/store.ex),
[cache triggers](../priv/repo/migrations/20261013143545_add_schedule_cache_revision.exs).

A recovery freeze cannot be implemented by hiding the upload button. Initial
disaster recovery may use full maintenance: stop application processes and
background workers, exclude deployments/release commands, identify and suspend
external writers, and verify no application writer remains connected. Exact host
commands and access paths must be verified in staging before being used in
production. A proven comprehensive read-only mode does not currently exist in
this inventory.

## Read-only operational evidence to collect

An operator with the existing authorized connection should collect only bounded,
non-secret outputs and record the observation time:

1. Installed deployment SHA from the release's `priv/deploy_sha`, corresponding
   Actions run, and service status/version. Inspect selected systemd properties;
   avoid dumping environment variables or entire secret-bearing units.
2. PostgreSQL server version and the ordered `schema_migrations.version` values,
   using the existing database access mechanism and a read-only transaction.
   Do not print the connection URL or query resident records for this inventory.
3. Service/proxy topology, scheduled jobs and other database writers. Record the
   private operational reference rather than copying sensitive configuration.
4. Backup type, most recent verified backup time, retention, encryption/off-host
   storage, failure alerts, WAL/PITR availability and existing restore evidence.
5. Staging destination, isolation boundaries, access profile and ownership. Confirm
   that a staging credential cannot select the production database accidentally.
6. Recovery owner, targets, rollback window and maintenance procedure.

Keep credential values, backup contents and private resident evidence outside Git.
Supply connection/profile names rather than pasting secrets into the chat.

## Step status and next PRs

- Complete: current source baseline, repository deployment inventory, mutation
  inventory and explicit access/evidence gaps.
- Pending: live deployment/schema/runtime observations, named operational owners,
  accepted recovery targets, backup evidence and a verified write-freeze procedure.
- Next Step 2 PR: persistent staging, once its destination and access are known.
- Independent Step 3 PR: artifact retention and deployment serialization can be
  prepared and tested locally while operational access remains unresolved.
- Steps 4–8: prepare tooling separately as feasible; do not mark operational
  rehearsals complete from documentation or local mocked tests.

Step 1 remains operationally open. No production deployment, backup restore,
service stop, staging provisioning or data migration was performed for this record.
