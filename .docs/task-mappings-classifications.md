# Task mappings and classifications

This increment implements PR 2 of the
[mappings and classifications plan](schedule-mappings-classifications-plan.md),
following merged [PR #90](https://github.com/jeffreybaird/residency-schedule/pull/90).
It adds stored task meanings and classification evidence. Existing importers,
schedule projections and consumers continue to use their existing paths.

## Separate recognition, equivalence and classification

The catalogue uses stable string activity codes from existing reviewed rotation
definitions. A presentation fallback such as `unknown` or `qgenda_assignment`
does not establish a clinical service.

Task mapping revisions retain the source namespace, literal task label,
normalization policy, recognition evidence and reviewed target codes. A task can
have zero, one or several targets. Recognition and equivalence are separate:
a recognized clinic without a reviewed service equivalent remains unclassified.
Source-specific rules stay separate: QGenda uses exact labels, while CSV uses
the existing abbreviation normalization. Their versions are `qgenda_exact_v1`
and `csv_abbreviation_v1`. Labels are bounded to 512 bytes.

Each stored classification belongs to a saved source occurrence and retains
the source facts, mapping revision and named rule revision used to interpret it.
Live source deletion must preserve the historical evidence. It must not block
ordinary roster replacement or academic-year deletion.

## Conservative outcomes

| Outcome | Meaning |
| --- | --- |
| `resolved` | Reviewed evidence identifies one activity type. |
| `context_required` | Multiple targets or a contextual policy prevent a global classification. |
| `recognized_unclassified` | The task is recognized but has no reviewed equivalent. |
| `unmapped` | No reviewed mapping establishes a meaning. |
| `conflicting` | Existing evidence or changed inputs prevent safe interpretation. |

For example, `SMH GYN R2 Day` has one reviewed Strong gynecology target.
`SMH Obstetrics Resident 1st Contact Night` retains its night-float and weekend
night targets and remains context-required. No target is chosen by list order,
label keywords or weekday inference.

The reviewed Saturday Highland gap exception is retained as named policy
metadata. Existing readers continue to evaluate it with their current context.
The initial rule version is `legacy_task_classification_v1`, with named policies
for unique equivalence, rotation context, recognition-only and unmapped outcomes.
The Friday Strong boundary correction is unchanged and is not applied again
by this backfill. Base rotations, coverage precedence, simultaneous duties,
notes, blank cells and explicit OFF/cancellation semantics remain intact.

## Legacy seeds and backfill

Legacy seed facts come from the existing CSV abbreviation map, QGenda recognized
task list and exact `TaskEquivalence` relations. Their origin is legacy code,
not a newly invented human approval. Public read-only accessors keep these facts
aligned with the existing policies.

Backfill walks stable source IDs in batches of 1–1,000, defaulting to 500.
It writes missing results,
rechecks source and mapping facts before persistence and preserves custom or
reviewed results. Repeating the same rules against unchanged inputs leaves the
stored results unchanged. Changed facts require explicit comparison and later
reclassification; they do not silently rewrite earlier evidence.

With the repository running, the context is `ResidencySchedule.TaskMappings`:

```elixir
alias ResidencySchedule.TaskMappings

{:ok, seed_counts} = TaskMappings.seed_legacy()
{:ok, interpretation} = TaskMappings.classify(:qgenda, "SMH GYN R2 Day")
{:ok, counts} = TaskMappings.backfill(batch_size: 500)
```

Seeding is explicit and repeatable. Its counters are `activity_types_added`,
`mappings_added`, `unchanged` and `conflicting`. A legacy policy change appends
a mapping revision; a custom/reviewed current mapping is preserved and reported
as a conflict. Earlier classification evidence is retained.

`classify(namespace, label)` is read-only and returns `{:error, :not_seeded}` when the
catalogue has not been initialized. Its result includes `status`,
`activity_type_code`, `target_codes`, `mapping_id`, `mapping_revision`,
`rule_version` and named `policy`. Unsupported rules or mapping facts that
contradict their saved legacy evidence produce a conflicting interpretation,
with no resolved type. `normalize_key(namespace, label)` returns
the versioned lookup key. Neither call changes the current importer.

After deploying the reviewed schema, the compiled-release operation seeds the
legacy facts and then backfills saved source occurrences:

```sh
bin/residency_schedule eval 'IO.inspect(ResidencySchedule.Release.backfill_task_classifications())'
```

Migration `20261028190000_run_phase2_backfills` runs this backfill once during `Release.migrate()` on the next deployment (the `:run_phase2_backfills_on_migrate` flag is off in the test environment); the manual command above remains the verification and rerun path and reports zero new rows once the migration has run. The release result separates `seed` counters from `classifications` counters.
Backfill reports `processed` as the number of newly inserted results, with
`resolved`, `context_required`, `recognized_unclassified` and `unmapped` counting
those new outcomes. `conflicting` counts retained results whose inputs or rules
have changed and new occurrences whose mapping cannot safely be classified;
these conflicts do not increase `processed`. `unchanged` counts results left intact, including custom/reviewed
results. A missing result against a protected custom/reviewed mapping is also
reported as conflicting and is left for explicit review; read-only `classify`
can still describe that mapping. Automatic records do not invent a human
approver. A completed repeat has zero new results, while unchanged or conflict
counts may remain nonzero.

Invalid source scope (`:inconsistent_source_scope`), unsupported source kind
(`:unsupported_namespace`) or an invalid persisted task label
(`:invalid_source_task`) returns a tagged error and rolls back the current batch.
Blank, NUL-containing and oversized labels are invalid; no meaning is invented
for them. Earlier completed batches remain and may be retried. These
operations use the existing deployment/operator locking discipline; they are
separate from schema deployment. See the
[verification record](task-mappings-classifications-verification.md) for local
checks and their limits. This document does not establish production execution.

## Delivery boundaries

No source dates, raw task labels, activity identity, import fingerprints or
coverage links are rewritten. There is no mapping-management UI, new taxonomy
for every clinic, arbitrary rule language or reader/writer cutover in this PR.
Exact timing remains a separate increment.

The [snapshot-and-rebuild decision](schedule-adapter-recovery-decision.md) remains
in effect; this work adds no recovery program or backup activation gate.
