# Plan: mappings and classifications

Plan approved for PR 1 implementation on October 27, 2026. The resident identity
mapping increment starts from `main` commit `1cec070`, after merged
[PR #89](https://github.com/jeffreybaird/residency-schedule/pull/89). Task mappings
and classifications remain planned separately. PR 1 is implemented on this
branch; its [operator contract](resident-identity-mappings.md) and
[verification record](resident-identity-mappings-verification.md) describe the
delivered API and local evidence. Deployment and production backfill are separate.

## Goal and delivery order

Persist reviewed source-to-person links and source-task meanings without making
names or display labels into identities. Preserve the current schedule output
while adding the representation that later readers and writers will use.

Use two implementation PRs, each containing its own additive schema, backfill,
tests and operator instructions:

1. Resident identity mappings.
2. Task mappings, classification rules and stored classification results.

Exact timing metadata follows in a separate increment. New read/write cutovers
remain the later phases of the [model plan](schedule-adapter-release-plan.md).
There is no new recovery program. [PR #84](https://github.com/jeffreybaird/residency-schedule/pull/84)
was closed without merging under the [recovery decision](schedule-adapter-recovery-decision.md).

## Existing behavior to preserve

| Area | Current source of behavior | Constraint |
| --- | --- | --- |
| CSV identity | `NameNormalizer` roster plus `ResidentLinker` proposals and admin-confirmed links | A first-name suggestion is not a reusable identity approval. Do not rewrite resident names or merge people. |
| QGenda identity | Unambiguous full names, or a year/position/expected-name crosswalk in `QgendaPreview` | Unmatched and ambiguous staff stay unresolved; exact-name conflicts remain errors. Uploaded crosswalks currently apply only to that preview. |
| CSV task labels | `CsvParser` abbreviations and special blank/OFF/date-update handling | Retain the existing namespace-specific normalization, warnings and date-boundary rules. |
| Recognized QGenda tasks | `QgendaPreview.@known_tasks` | Recognition does not establish a service classification or working hours. |
| Service equivalence | Exact labels in `TaskEquivalence` | One task can match multiple existing rotation types. Do not replace this relation with a one-to-one lookup. |
| Gap and effective schedule | `TaskEquivalence.gap_type/2` and existing projection modules | Preserve context-dependent fallbacks, Saturday Highland nights, Friday Strong correction and coverage precedence. |

Examples: `SMH GYN R2 Day` has a reviewed Strong gynecology equivalent.
`SMH Obstetrics Resident 1st Contact Night` can match Strong night-float or
weekend-night headings; without the required context it remains a neutral daily
assignment. A clinic can be a recognized task without being equivalent to its
resident's general rotation. Unknown labels must remain visible.

## PR 1: resident identity mappings

### Proposed representation

Add `source_identity_mappings`, scoped by logical source namespace and schedule.
The namespace identifies the adapter/source domain, not a filename or uploaded
display label. Initially use explicit namespaces for the existing CSV and
QGenda inputs; do not build a tenant-management system.

Store the literal source key, its explicitly versioned lookup normalization,
target `schedule_resident_id`, status, evidence origin, revision and actual actor
when known. Derive the stable person ID from the membership. Do not store a
second independently editable person target or identify people by `R2-1` alone.
Membership must belong to the selected schedule. Source staff IDs can be used
when a future adapter actually supplies them; do not fabricate them from names.

Distinguish proposed/observed links from approved reusable mappings. Allow
conflicting observations to remain reviewable, with at most one active approved
target per namespace/schedule/lookup key. Mapping revisions retain their meaning;
do not mutate an old revision that existing evidence references.

### Population and backfill

- A reviewed crosswalk may be explicitly imported through an administrator-only
  context/release operation after current roster validation. Begin with a dry-run
  report of additions, existing matches, held links and conflicts. A general
  mapping-management UI is outside this increment.
- Do not silently turn an uploaded preview crosswalk into permanent approval.
  Reusable approval is a separate explicit operation.
- Existing saved activity sources provide observed source-to-membership links.
  Backfill those observations without relinking any activity. Repeated evidence
  for the same target may coalesce; disagreement becomes a conflict rather than
  choosing the newest name or record.
- Observed import associations alone do not prove approval for future reuse.
  Do not invent who approved a reusable mapping or when. Configured private
  roster/crosswalk files must be validated where available; they are not assumed
  to exist in Git or in every deployment.
- Preserve CSV linking and QGenda matching as separate policies. Do not export
  CSV first-name heuristics into QGenda identity matching.

Add a shared resolver with explicit statuses: matched, unmatched, ambiguous and
held/conflicting. At first, compare its proposed results with the existing path
using synthetic fixtures; existing matching remains authoritative. Version the
mapping inputs separately from the source-content fingerprint. When saved
mappings are later enabled for previews, commit must recheck both roster identity
and mapping revision; a stale preview must require a new preview.

### Acceptance

Tests cover the same label across two years/sources, identical-name ambiguity,
membership/person consistency, stale roster and mapping revisions, explicit
crosswalk approval, existing exact-name conflicts, administrator checks and
idempotent/conflict-preserving backfill. A changed mapping must never silently
reassign an already committed source cell or merge resident records.

## PR 2: task mappings and classifications

### Proposed representation

- `activity_types`: stable string codes and descriptions, seeded from existing
  reviewed service/rotation definitions. Display labels remain editable text.
  The `unknown` and `qgenda_assignment` presentation fallbacks are not evidence of
  a clinical service. Do not invent a broad taxonomy for every clinic now.
- `source_task_mappings`: namespace, literal task label, normalization policy,
  recognition status, evidence origin and immutable revision. QGenda uses the
  current exact-label matching; CSV retains its existing abbreviation policy.
- `source_task_mapping_targets`: zero or more reviewed activity-type targets per
  mapping revision. Preserve multi-target equivalence explicitly.
- `activity_source_classifications`: additive results for an existing source
  occurrence, retaining mapping/rule revision, status and a resolved type only
  where justified. Attach evidence to the source occurrence so two imports
  cannot silently overwrite each other's interpretation. Existing normalized
  rotation codes can link to the catalogue without rewriting `rotation_type`.

Use small named, versioned policies implemented in code for existing contextual
rules. Do not introduce an arbitrary expression language or execute imported
rule text. In particular, keep rotation-heading equivalence distinct from the
rule for classifying a task when there is no base rotation.

### Seed and classify conservatively

Seed the existing CSV abbreviation map, recognized-task list and reviewed exact
`TaskEquivalence` relations as separate facts. Mark these as legacy code rules,
not newly approved human decisions. Do not infer equivalences from the recognized
task list or from words such as GYN, Clinic or Night.

Use these classification outcomes:

| Outcome | Meaning |
| --- | --- |
| Resolved | Existing reviewed evidence establishes the type. |
| Context required | Multiple targets or a contextual policy prevent a global one-to-one classification. |
| Recognized, unclassified | The task is known but has no reviewed service equivalent. |
| Unmapped/conflicting | Preserve the raw label and evidence for review; do not guess. |

Do not resolve multi-target tasks by choosing the first target or by inferring a
service from the weekday. Preserve the specifically reviewed Saturday Highland
gap rule as a named exception. Initial stored results may remain context-required
until the later effective-schedule comparison evaluates the relevant context.
Existing readers continue to apply the existing rules in this increment.

### Backfill and acceptance

Backfill by stable record IDs in bounded batches. Record the applied rule revision;
fill missing results without overwriting reviewed/custom results. Mapping changes
create an explicit new comparison/reclassification operation, not a silent rewrite
of earlier classifications. Report processed, resolved, context-required,
recognized-unclassified, conflicting and unchanged counts. A completed repeat is
a no-op for the same rules and unchanged inputs.

Tests must preserve exact-label behavior, multi-target equivalence, recognized
clinics, unknown tasks, simultaneous duties, notes, base-rotation and coverage
precedence, Saturday Highland fallback and Friday Strong correction. Compare
normalized schedule meaning across resident/calendar views, statistics, coworker
queries, assistant queries and calendar exports using existing fixtures. Do not
change event identity, source dates, task text, import fingerprints or coverage
links. Preserve blank versus explicit OFF/cancellation semantics.

## Shared implementation constraints and completion evidence

- Use additive tables/columns and database constraints/FKs for scoped uniqueness
  and target integrity. Retain old fields and code paths during this phase.
- Apply the repository's test-writer, runner, implementation and independent-review
  workflow. Test migration SQL against populated legacy-shaped data and inserts
  that omit the new fields, not only a newly created database.
- Recheck changed source facts, roster targets and revision at each batch update;
  make retries idempotent. Do not hold one transaction over the complete backfill.
- Follow the source-provenance precedent: explicit compiled-release backfill tasks
  with aggregate readback, plus documented repeated-zero/no-change validation.
  Existing code keeps working between schema deployment and backfill completion.
- Keep private names/crosswalks out of committed fixtures and reports. Use
  synthetic examples and aggregate conflict counts.
- Record actual deployment/migration/backfill results separately from local test
  evidence. The successful deployment workflow for #88 is known, but its manual
  production backfill is not confirmed by repository evidence; verify it locally
  before relying on complete provenance references.

Done for this planned increment means the two additive representations and their
backfills are tested, reviewable and documented, with differences explicitly
reported. It does not mean the new classifications have replaced current
schedule behavior. Reader/writer cutover and exact timing remain separate work.

## Advisory prerequisite completed

The audit findings discovered during planning were addressed separately in
[PR #89](https://github.com/jeffreybaird/residency-schedule/pull/89), now merged.
Bandit is locked to 1.14.0 and plug_crypto to 2.2.1. See the
[advisory verification](october-27-advisory-fixes-verification.md) for identifiers,
patch metadata and validation. Run fresh ordinary dependency checks for this
increment rather than relying on the previous audit as current evidence.
