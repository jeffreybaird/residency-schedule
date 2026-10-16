# Schedule adapter migration release plan

Status: proposed release sequence; implementation has not started.
Recorded: October 15, 2026.
Code baseline reviewed: `88fb94d0b2a6638622eb2b25ee5d53e3ea83ebd6`.

Make schedule ingestion independent of uploaded file formats through a shared
import contract, pluggable adapters, and a shared effective-schedule service.
Release the transition in independently reversible increments. Preserve current
behavior before introducing new import semantics.

The next implementation scope is Phase 0 and Phase 1. The detailed first-phase
runbook is [Phase 0 recovery readiness](schedule-adapter-phase-0.md).
This plan does not authorize a production deployment or data migration.

## Architecture and invariants

The target flow is:

```text
CSV / QGenda / custom adapter
  -> shared import document
  -> identity and activity mapping
  -> validation and previewed change plan
  -> transactional schedule writer
  -> schedule records and provenance
  -> effective-schedule service
  -> views, statistics, assistant queries and calendar exports
```

Keep rotation blocks and dated activities as distinct domain concepts: a weekly
gynecology rotation can coexist with an afternoon clinic. Both use stable person
and schedule-membership identities, canonical activity codes, explicit date and
time semantics, dated notes, and generic provenance. Display labels and source
coordinates do not determine domain identity.

Adapters describe source facts. Application services own identity resolution,
authorization, schedule policy, validation, reconciliation and persistence.
The builder and editor submit domain changes without depending on parser structs.

Preserve these invariants throughout the transition:

- Keep person, membership and rotation IDs stable, including references from
  coverage requests and overrides.
- Preserve simultaneous activities, unknown labels, notes and provenance.
- Distinguish missing information, explicit OFF instructions and cancellations.
- Keep import scope explicit: schedule, people, dates, record kinds and source
  completeness. Partial exports never imply deletion of absent assignments.
- Preserve existing night-boundary, coverage and classification behavior. Review
  intentional behavior changes separately; never adjust legacy dates twice.
- Keep source occurrence identity separate from equivalent schedule facts.
  A file fingerprint identifies an upload; it cannot identify every correction
  across changed files. Ambiguous corrections require review.
- Preserve timing precision. Period-only labels do not establish exact hours.
- Keep one authoritative writer. Any compatibility fields are maintained in its
  transaction, not through independent old and new writes.

## Known deployment constraints

At the reviewed baseline, [deployment](../.github/workflows/deploy.yml) runs on
pushes to `main`, requires the test job, migrates before restarting the service,
and restores application files when its startup HTTP check fails. That rollback
does not restore the database. The previous release directory is deleted after
a successful startup check.

Demo and production deploy in parallel. Demo reloads its fixture on each deploy;
it is not a persistent staging or migration-rehearsal environment. Backup, restore
and point-in-time recovery readiness must be verified operationally; repository
inspection does not establish whether those facilities exist on the server.

## Release sequence

| Phase | Scope | Gate before advancing | Recovery |
| --- | --- | --- | --- |
| 0: Recovery readiness | Persistent staging, serialized deployment, retained artifacts, restore rehearsal, semantic smoke checks and runbooks. | Demonstrated application rollback and database restore, with recorded recovery duration and data-loss limits. | Current application remains authoritative. |
| 1: Adapter boundary | Shared import document, adapters around existing parsers, shared preview orchestration and builder domain input. Retain existing persistence and rendering; new adapters remain preview-only. | Existing formats produce equivalent previews and writes. A simple JSON adapter works without core persistence or view changes. | Disable the entry point or restore the previous compatible release. |
| 2: Additive schema | Generic provenance, mappings, classifications and timing metadata; small restartable backfills. Keep existing columns and IDs. | Complete reconciliation of records, notes and references; repeat execution makes no changes. | Stop backfill and use legacy fields; leave additive schema installed. |
| 3: Compare new reads | Compute new effective schedules alongside old reads; users receive old results. | Zero unexplained semantic differences and acceptable measured performance. | Disable comparison. |
| 4: Enable new reads | Enable one selected schedule, then expand using consistent routing across consumers. | Administrator review, performance checks and observation covering actual imports and edits. | Restore legacy reads for the schedule and invalidate caches. |
| 5: Enable new writes | Common writer for existing formats first; controlled import followed by expansion and new adapters. | Reimport, correction, concurrency, stale-preview and recovery scenarios pass; writes match the preview. | Pause affected mutations; use the compatible rollback release or a reviewed compensating change. |
| 6: Retire compatibility | Remove old paths and obsolete columns in a separate release. | Broad adoption, at least two real import/edit cycles and expiration of the agreed rollback window. | Forward repair or rehearsed recovery; ordinary binary rollback is insufficient. |

Each release has its own PR, validation evidence and rollout decision. Deployment
does not automatically authorize advancing to the next phase.

## Comparison and acceptance contract

Compare normalized schedule meaning against the same data revision. Cover:

- April 5–18 vacation assembled from roster weekdays and imported weekends,
  including all dated notes and the complete coworker/detail range.
- A rotation and a clinic on the same day; distinct simultaneous duties.
- Imported gap filling and approved coverage precedence.
- Highland and Strong overnight boundaries and Friday corrections.
- Blank input, OFF, incomplete exports, unknown tasks and changed labels.
- Identical reimports, ambiguous people and corrections after earlier imports.
- Stable identities, reference integrity, service/shift counts and all consumers.
- Calendar event identities, dates and times; changed UIDs can duplicate events
  in subscribers' calendars even when rendered labels match.

Row counts alone are insufficient. Every unexplained semantic difference blocks
promotion. Record intentionally approved differences separately from regressions.
Use synthetic regression fixtures; keep resident-level comparison evidence in
an access-controlled administrative location. Export only aggregate mismatch
counts through telemetry, following existing privacy rules.

## Rollout controls and backfill

Implement independent controls for comparison, read version by schedule, adapter
enablement and write version. Provide a way to pause affected mutations,
including editor, identity and coverage changes. These controls are planned;
they do not exist merely because they are listed here.

Route by schedule rather than randomly by request. Apply the decision across
views, exports, statistics and assistant queries. Include projection version in
cache identity and refresh active views when switching versions.

Backfill from stored records. Mark unavailable historical source information as
legacy provenance. Record migration version, affected IDs, progress and results.
Recheck concurrently changed records before updating them. Before writer cutover,
briefly pause relevant mutations, catch up the backfill and reconcile the final
state. Include every schedule involved in a cross-schedule coverage operation.

Retain the legacy representation until all readers and writers have migrated and
the rollback window expires. Before Phase 5, designate the minimum compatible
rollback release and prove it can read and preserve all data the new writer can
create. Gate new-only semantics until that release is deployed and tested.

## Incident response and stop conditions

| Incident | Response |
| --- | --- |
| Incorrect display or calculation | Disable new reads, invalidate caches and verify legacy results. |
| Incorrect committed import | Pause affected mutations, preserve evidence, inspect subsequent edits and coverage references, then apply a reviewed compensating change. |
| Widespread corruption | Enter maintenance mode and execute the rehearsed restore/replay procedure. |

Database restore can discard valid writes after the recovery point. Treat it as
a last recovery option; never present application rollback as undoing a migration.

Stop rollout for any unexplained identity change, missing assignment or note,
broken coverage reference, wrong overnight boundary or non-idempotent import.
Also stop for sustained errors, lock contention or latency beyond thresholds set
from rehearsal. A successful startup HTTP check is not semantic validation.

For the first production read rollout, use a minimum seven-day observation period
plus two actual import/edit cycles. Time without relevant activity is insufficient.
Run project checks and follow the current
[Bandit patch-check procedure](bandit-http2-audit-exception.md) before every commit;
the existing exception is not a blanket security-audit bypass.

## Release record

For each release, record the owner and decision maker, artifact SHA and checksum,
schema versions, minimum compatible rollback release, enabled controls, test and
comparison evidence, backup/recovery evidence, performance thresholds, rollout
scope, stop conditions, rollback procedure and observed outcome. Keep operational
secrets and resident-level evidence out of Git.
