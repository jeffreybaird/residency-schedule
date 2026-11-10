# Evidence-driven effective reads: implementation contract

Recorded October 28, 2026 after the isolated legacy fixes in PRs #97–100.
Friday policy evidence is enriched by the subsequent metadata prerequisite.
This refines the [Phase 3 plan](schedule-effective-read-plan.md) where inspection
found that stored evidence cannot express every proposed semantic distinction.
It does not authorize a consumer switch or approve comparison differences.

## Evidence and diagnostics

The fixed daily/calendar service APIs remain unchanged. The additional
`evidence_diagnostics(schedule_id, version)` API returns deterministic in-memory
observations. Comparison adds a numeric `unresolved_evidence` field and retains
diagnostic detail only in `detail.evidence`. Release output and telemetry may
export aggregate counts only. Equal daily records are insufficient evidence of
readiness when unresolved evidence remains; no automatic readiness flag is added.

Diagnostics use fixed reasons and original activity/source/membership/date keys.
Missing source identity evidence preserves the existing Activity membership with
a diagnostic. Held, ambiguous or contradictory identity evidence excludes that
source-derived duty and retains the evidence in diagnostics; base rotations stay
unchanged. No name-matching fallback silently establishes identity.

Missing classification remains visible as a neutral unresolved assignment.
Missing timing remains date-only. Invalid contradictory classification or timing
excludes the affected source-derived duty with a diagnostic, retaining independent
valid occurrences. Independent AM and PM occurrences are simultaneous duties, not
contradictions merely because their periods differ. Identical facts deduplicate
without losing distinct precision or service evidence.

No read backfills or writes evidence. Synthetic tests explicitly create Phase 2
evidence using existing fixture/backfill interfaces. Current importer paths do
not maintain every Phase 2 row after the one-time backfills, so freshness remains
a comparison-readiness limitation until later writer work or deliberate backfill.

## Distinctions not established by current evidence

- Literal QGenda OFF is stored as unmapped classification with no semantic target.
  V2 preserves its unresolved label; it cannot declare explicit off by matching
  raw text or a retained label snapshot. Upstream semantic evidence is required.
- A recognized clinic with period AM establishes a dated activity and period,
  not a service equivalence or exact clock hours. A simultaneous clinic can be
  visible beside a base rotation; that difference must be classified separately.
- Historical contact-night and gynecology-night mappings retain the same Strong night
  target pair and generic `rotation_context_v1` policy. Legacy Friday correction
  specifically requires contact-night evidence. V2 must not broaden that trigger
  to all Strong night tasks or identify it by matching raw/snapshot labels.
  The metadata prerequisite now stamps `friday_strong_correction_v1` for new
  contact-night occurrence evidence. V2 applies that explicit policy. Historical
  generic evidence remains immutable; where the specific policy is unavailable,
  V2 retains base geometry and reports `insufficient_policy_evidence`.

These limitations mean this computation alone does not establish Phase 3
acceptance. Every resulting mismatch still requires classification, and the
Friday policy requires sufficient stored semantic evidence for each occurrence.
Historical generic occurrences still require explicit append-only enrichment
before their comparisons can pass. Production comparisons have not been run.

## Identity, timing and output stability

Preserve existing base and coverage calendar UIDs through projection splits;
do not reconstruct their segment identities solely from daily records. New
activity events are compared separately. Exact source instants and timezone
remain exact; date-only and period evidence never manufacture exact hours.
Daily duties and diagnostics use total deterministic ordering, including label
and timing distinctions. Consumers continue receiving legacy results.
