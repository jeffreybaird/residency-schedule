# Effective-schedule read decisions

Recorded October 28, 2026 for the [Phase 3 read plan](schedule-effective-read-plan.md).

## User-approved direction

After reviewing the plan and merged PR #96, the user authorized the recommended
defaults: “I still don't understand the bugs, so lets go with your r3ecommendations”.
The recommendation was to fix demonstrated legacy bugs, resolve context-required
tasks using stored evidence and day context, and review every resulting difference
before switching consumers.

- Investigate and fix the plan's coverage-segment, cross-schedule gap-filling,
  and month-summary inconsistencies as legacy defects in separate changes.
  Preserve intentional override-protected behavior; a suspected defect must be
  demonstrated by a regression test before changing it.
- Fix the zero-length all-day calendar event identified in PR #96 while
  preserving its UID.
- Keep duty-hour overlap behavior within the existing estimate model. This
  direction does not approve arbitrary changes in estimated hours.
- Resolve context-required activity classifications using the day's base rotation
  and weekday rather than retaining a generic assignment solely for compatibility.
  Recognition alone does not establish a service.

## Approved v2 differences — October 29, 2026

The user explicitly answered “Approve both improvements” for these two
synthetic scenarios:

- A morning clinic remains visible as a distinct dated duty with its retained
  AM period alongside the main rotation, instead of being omitted by legacy
  reads. Its additional activity calendar event is an approved difference.
- An activity with retained exact start/end instants preserves those instants
  in v2 and its calendar event instead of becoming an all-day event. Existing
  base and coverage event identities remain unchanged.

Approval applies to these behavior differences only. Missing or conflicting
evidence still blocks acceptance; this does not approve arbitrary mismatches.

## Comparison acceptance

These decisions authorize implementation direction, not blanket approval of
comparison mismatches. Each demonstrated difference must still be classified as
`regression`, `legacy_defect`, or a specifically approved change under plan D4.
Record synthetic scenarios and the applicable decision here as they are reviewed;
do not store resident-level comparison results in this document or other files.

No production comparison or consumer switch is established by this record.
