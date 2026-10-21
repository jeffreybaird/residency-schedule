# Schedule import adapter boundary

Phase 1 separates uploaded source formats from schedule reconciliation and
persistence. The [owner's recovery decision](schedule-adapter-recovery-decision.md)
retires the older Phase 0 program; it has no remaining acceptance gates.

## Contract and compatibility

`ResidencySchedule.Importer.ImportDocument` carries source facts, the selected
academic year, explicit import scope and completeness, warnings, rotation-roster
input or dated activities, and source notes. Its `Resident` struct is a domain
input: the builder and schedule writer do not need to construct a CSV parser
struct.

The CSV and QGenda adapters wrap the existing parsers. Parsing remains separate
from resident matching, crosswalk validation, permissions, previewing and writes.
`ResidencySchedule.Importer.Preview.prepare/3` provides the common preview entry
point; existing upload entry points retain their existing result shapes.

The existing persistence and rendering remain in use. In particular:

- CSV whole-year replacement and date updates retain their distinct behavior.
  Blank or unknown date-update cells preserve data; explicit OFF cells clear it.
- QGenda documents are partial sources. Missing assignments do not mean deletion.
  Simultaneous activities, unknown labels, dated notes and source coordinates are
  preserved. The original parsed-map fingerprint remains unchanged, preserving
  existing import identity.
- The builder supplies domain resident input while retaining current date-boundary
  normalization. Dates must not receive legacy overnight adjustments twice.
- No database migration or new schedule read representation is introduced.

## JSON proof adapter

The JSON adapter demonstrates another source using the same activity
reconciliation without changes to database storage or views. It is available
through the preview API, not a new upload UI or a production write route.
Its previews are explicitly marked preview-only; the existing detailed-assignment
commit API must reject them even for administrators.

The small input format uses an integer `academic_year`, an `assignments` list,
optional `header_dates`, and optional `notes` and `unlinked_notes`. Dates are ISO
8601 strings. Assignments carry literal `raw_staff` and `raw_task`, optional note
strings, and optional `source_sheet` and `source_cell` coordinates. A standalone
note has string `text` and optional source coordinates. Standalone notes remain
visible for review rather than being silently attached to an assignment.
The preview's date scope includes every assignment date as well as any supplied
header dates, so an empty or partial header list cannot hide an activity date.

```json
{
  "academic_year": 2026,
  "header_dates": ["2026-12-28"],
  "assignments": [
    {
      "date": "2026-12-28",
      "raw_staff": "Reed, Iris",
      "raw_task": "Clinic AM",
      "notes": ["Bring kit"]
    }
  ]
}
```

The adapter bounds input bytes and record counts, validates data types, and does
not turn uploaded strings into atoms. Matching retains the existing conservative
full-name/crosswalk rules. New source formats do not authorize new write semantics.

## Validation and next scope

The [verification record](schedule-adapter-phase-1-verification.md) records the
accepted test contract, expected failures before implementation, final checks and
review limits. Existing importer and builder tests remain the compatibility
baseline. Production deployment and data changes are separate from this delivery.

The subsequent additive-schema phase covers generic provenance, mappings,
classifications and timing metadata. It is separate from establishing the adapter
boundary.
