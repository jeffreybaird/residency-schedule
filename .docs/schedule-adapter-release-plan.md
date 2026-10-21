# Schedule adapter migration release plan

Status: Phase 1 adapter boundary implemented locally; Phase 2 additive schema is
next. The [old recovery program is canceled](schedule-adapter-recovery-decision.md).
See the [Phase 1 contract](schedule-adapter-phase-1.md) and
[verification record](schedule-adapter-phase-1-verification.md) for checks and limits.
Recorded: October 15, 2026.
Code baseline reviewed: `88fb94d0b2a6638622eb2b25ee5d53e3ea83ebd6`.

Make schedule ingestion independent of uploaded file formats through a shared
import contract, pluggable adapters, and a shared effective-schedule service.
Release the transition in small, tested increments. Preserve current
behavior before introducing new import semantics.

Phase 1 retains existing persistence and rendering. The next model work is
Phase 2's additive schema. The old Phase 0 recovery program is retired, with no
pending recovery deliverables or gates. Production deployment and data migration
remain separate actions on a reviewed implementation.

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

## Implementation sequence

| Phase | Scope | Acceptance |
| --- | --- | --- |
| 1: Adapter boundary (implemented locally) | Shared import document, CSV/QGenda adapters, shared previews and builder domain input. Existing persistence and rendering retained; JSON is preview-only. | Existing formats retain their behavior; a new adapter can preview without storage or view changes. |
| 2: Additive schema (next) | Generic provenance, mappings, classifications and timing metadata; small restartable backfills. Keep existing columns and IDs. | Records, notes and references reconcile; repeating the backfill makes no changes. |
| 3: Compare new reads | Compute new effective schedules alongside existing reads; users receive existing results. | No unexplained differences in schedule meaning; acceptable measured performance. |
| 4: Enable new reads | Enable a selected schedule, then expand consistently across consumers. | Representative views, exports, statistics and assistant queries agree. |
| 5: Enable new writes | Common writer for existing formats first, then deliberate enablement of new adapters. | Reimport, correction, concurrency and stale-preview tests pass; writes match the preview. |
| 6: Retire compatibility | Remove old paths and obsolete columns in a separate change. | All consumers migrated and representative import/edit validation passes. |

Keep each delivery reviewable with its tests and observed results. There is no
Phase 0 closeout, minimum observation period or required number of real import
cycles before continuing.

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

Retain the legacy representation while readers and writers still need it.
Remove compatibility only after the new paths pass their correctness checks.
No designated rollback release or rehearsed rollback program is required.

## Checks and simple fallback

Run the project's tests, formatting, static checks and current dependency audit.
Stop and fix unexplained identity changes, missing assignments or notes, broken
coverage references, wrong overnight boundaries or non-idempotent imports before
shipping. Use representative synthetic schedules to validate reads and writes;
a successful startup check alone does not validate schedule behavior.

If a deployed change fails, fix it or use the existing deployment tooling where
compatible. If the database needs recovery, stop writes, rebuild the server if
necessary and restore the available snapshot. Downtime and post-snapshot write
loss are accepted for this family app. Application rollback does not undo a
database migration.

Before a production data change, note the snapshot being relied on and the
[existing server setup/deployment instructions](../DEPLOY.md). No PITR,
independent monitoring, backup activation, recovery-time guarantee or formal
restore rehearsal is part of this migration plan.

For each delivery, record what changed, the relevant tests, any data changes and
the deployment outcome when deployed. Keep operational secrets and resident-level
evidence out of Git.
