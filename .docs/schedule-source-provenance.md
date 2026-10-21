# Source provenance: first additive schema delivery

This is the first part of Phase 2 of the
[model migration plan](schedule-adapter-release-plan.md). It adds source metadata
to existing records without replacing their tables or changing their identities.
Mappings, classifications, exact timing and new-format write enablement remain
separate work.

## Stored fields

| Existing table | Addition | Existing-record meaning |
| --- | --- | --- |
| `detailed_import_batches` | `source_kind`, `source_metadata` | These batches came from QGenda; retain their fingerprint, schedule, actor and header range. |
| `detailed_activity_sources` | `source_reference` | A generic map containing the known worksheet and cell. Keep the existing coordinate columns and unique index for compatibility. |
| `rotations` | `source_kind`, `source_metadata` | Use `legacy` with empty metadata where the original source is unknown. Do not infer a filename, actor or upload time. |

Schema defaults preserve legacy inserts that omit the new fields. New QGenda
writes populate generic references in the same transaction as existing batch,
activity and source records. Current CSV, builder and editor writes record their
known origin; unknown callers retain the explicit legacy default. Date-update
fragments retain their prior provenance rather than attributing unchanged dates
to the new import.

Rotation provenance describes the current record's latest writing origin, not a
complete edit history. A real editor change records `editor` and clears stale
source metadata; an unchanged save preserves the existing provenance. New CSV
date ranges record `csv`, while surviving fragments keep their original metadata.

The generic reference is descriptive metadata, not a replacement identity. The
existing QGenda occurrence key, import fingerprint and activity deduplication
continue to govern reimports. Original sheet/cell fields and their constraints
remain installed. JSON remains preview-only.

## Backfill

The schema migration adds the fields and supplies the known batch/unknown
rotation defaults. Worksheet/cell references are backfilled separately in small
keyset batches; they are not a large startup data migration.

After deploying the reviewed release and noting the database snapshot being
relied on, run from the installed release using its existing runtime configuration:

```sh
bin/residency_schedule eval 'IO.inspect(ResidencySchedule.Release.backfill_source_provenance())'
```

The command prints `{:ok, %{activity_sources_updated: count}}`. The context API
`ResidencySchedule.SourceProvenance.backfill(batch_size: 500)` supports batch
sizes from 1 to 1,000. It fills empty references for QGenda sources, skips other
source kinds and already populated references, and preserves timestamps and
existing metadata. A completed repeat run reports zero updates. If interrupted,
rerun the same command; completed batches remain valid.

No assignment dates, resident IDs, rotation IDs, notes or coverage references are
rewritten by the migration/backfill. The utility does not infer missing
historical source facts. Existing application reads and imports remain in use.

## Validation and scope

The [verification record](schedule-source-provenance-verification.md) records
populated legacy-schema migration checks, legacy insert compatibility, backfill
repetition, writer behavior and the final test/review results. Local synthetic
validation is separate from production deployment and backfill execution.

The next schema delivery addresses mappings and classifications, followed by
timing metadata. The [retired recovery program](schedule-adapter-recovery-decision.md)
adds no prerequisites to this work.
