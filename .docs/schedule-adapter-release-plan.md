# Schedule adapter migration release plan

Status: Phase 0 safeguards delivered in part; Phase 1 adapter boundary implemented
locally under the [October 21 recovery decision](schedule-adapter-recovery-decision.md).
See the [Phase 1 contract](schedule-adapter-phase-1.md) and
[verification record](schedule-adapter-phase-1-verification.md) for checks and limits.
Recorded: October 15, 2026.
Code baseline reviewed: `88fb94d0b2a6638622eb2b25ee5d53e3ea83ebd6`.

Make schedule ingestion independent of uploaded file formats through a shared
import contract, pluggable adapters, and a shared effective-schedule service.
Release the transition in independently reversible increments. Preserve current
behavior before introducing new import semantics.

Phase 1 retains existing persistence and rendering; production deployment remains
separate. The next model work is Phase 2's additive schema. Remaining Phase 0
operational work is deferred under the owner's revised recovery requirements. The original
[Phase 0 recovery runbook](schedule-adapter-phase-0.md) remains historical evidence,
not a prerequisite to Phase 1 development.
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

## Historical deployment constraints (October 15 baseline)

The following describes the original baseline, not current deployment behavior.
Delivered Phase 0 work added persistent staging, retained immutable releases and
deployment locks; see [the Phase 0 record](schedule-adapter-phase-0.md). Remaining
recovery work is deferred under the October 21 decision.

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
| 0: Recovery readiness (revised October 21) | Retain delivered tooling; defer further production backup activation, monitoring, PITR and recovery drills. | Does not block Phase 1 development. Before production data/schema changes, identify a usable database snapshot and rebuild instructions. | Owner accepts downtime and loss of changes after the snapshot; rebuild server and restore snapshot. |
| 1: Adapter boundary | Shared import document, adapters around existing parsers, shared preview orchestration and builder domain input. Retain existing persistence and rendering; new adapters remain preview-only. | Existing formats produce equivalent previews and writes. A simple JSON adapter works without core persistence or view changes. | Disable the entry point or restore the previous compatible release. |
| 2: Additive schema | Generic provenance, mappings, classifications and timing metadata; small restartable backfills. Keep existing columns and IDs. | Complete reconciliation of records, notes and references; repeat execution makes no changes. | Stop backfill and use legacy fields; leave additive schema installed. |
| 3: Compare new reads | Compute new effective schedules alongside old reads; users receive old results. | Zero unexplained semantic differences and acceptable measured performance. | Disable comparison. |
| 4: Enable new reads | Enable one selected schedule, then expand using consistent routing across consumers. | Administrator review, performance checks and observation covering actual imports and edits. | Restore legacy reads for the schedule and invalidate caches. |
| 5: Enable new writes | Common writer for existing formats first; controlled import followed by expansion and new adapters. | Reimport, correction, concurrency, stale-preview and recovery scenarios pass; writes match the preview. | Pause affected mutations; use the compatible rollback release or a reviewed compensating change. |
| 6: Retire compatibility | Remove old paths and obsolete columns in a separate release. | All consumers migrated, representative import/edit validation accepted and the rollback window explicitly closed by the owner. | Forward repair or restore the identified snapshot; ordinary binary rollback is insufficient. |

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
| Widespread corruption | Stop writes, rebuild the server if necessary and restore the identified database snapshot; accept post-snapshot write loss under the revised recovery decision. |

Database restore can discard valid writes after the recovery point. The owner
accepts that tradeoff for this four-user family app. Never present application
rollback as undoing a migration. Further recovery guarantees and rehearsals are
optional follow-up work, not implementation gates.

Stop rollout for any unexplained identity change, missing assignment or note,
broken coverage reference, wrong overnight boundary or non-idempotent import.
Also stop for sustained errors, lock contention or latency beyond thresholds set
from rehearsal. A successful startup HTTP check is not semantic validation.

For the first production read rollout, check representative schedule results and
the actual import/edit paths used by the family. The owner no longer requires a
fixed seven-day observation period or two real import/edit cycles as a recovery
gate; synthetic regression tests remain required for behavior changes.
Run project checks and follow the current
[Bandit patch-check procedure](bandit-http2-audit-exception.md) before every commit;
the existing exception is not a blanket security-audit bypass.

## Release record

For each release, record the owner and decision maker, artifact SHA and checksum,
schema versions, minimum compatible rollback release, enabled controls, test and
comparison evidence, backup/recovery evidence, performance thresholds, rollout
scope, stop conditions, rollback procedure and observed outcome. Keep operational
secrets and resident-level evidence out of Git.
