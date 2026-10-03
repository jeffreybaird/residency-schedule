# QGenda calendar preview

Milestone 1 adds a read-only preview of a QGenda **Calendar By Staff** Excel
export. It does not save assignments, rename residents, replace rotations, or
determine surgery availability.

## Using the preview

1. Sign in as an administrator and open **Upload Schedule** (`/admin/upload`).
2. Use the separate QGenda workbook form and select an existing academic year.
3. Upload the `.xlsx` export. If the server does not have the reviewed name
   crosswalk, also select its `.csv` file in the QGenda form, then preview.
4. Review matched and unmatched staff, missing roster members, unknown tasks,
   date coverage, daily assignments, and linked notes.
5. Use the preview filter and pagination to inspect assignments. Re-uploading
   replaces the current preview rather than appending another copy.

The existing CSV import workflow remains separate. The QGenda preview has no
commit action. Saving detailed assignments is a later milestone.

## Identity matching

QGenda supplies the preferred displayed name. Existing names remain useful for
matching; the preview does not change stored names. First-name similarity is
not sufficient to establish identity.

Reviewed aliases can be uploaded with the workbook for that preview. This is
useful when the existing schedule uses first names or nicknames and QGenda uses
full names. The preview indicates where its crosswalk came from. Uploaded
crosswalks apply only to that preview and are not saved on the server; supply
the file again when preparing another preview.

Alternatively, aliases can be supplied through a local server CSV whose default path is
`data/qgenda-resident-crosswalk.csv`. Configure another location using the
`:residency_schedule` application setting `:qgenda_crosswalk_path`.

The columns are:

```csv
academic_year,position_code,qgenda_staff,existing_name
2026,R2-1,"Reed, Iris",Iris
```

This example is fictional. Each link is scoped to a year and position and must
agree with the current resident name. Keep real crosswalks in ignored `data/`
or another private deployment location. A local ignored file is not delivered
by Git; configure it separately wherever the application runs. Missing mapping
data leaves unresolved names visible for review rather than guessing a match.
An uploaded crosswalk must pass validation for the selected year and current
roster. Malformed or inconsistent mappings must be corrected rather than used
to weaken identity matching.

If none of the residents match after deployment, first check the crosswalk
source shown in the preview. The ignored file on a developer's computer is not
automatically present in a production release. Compare its `existing_name` and
`position_code` against the selected production roster; uploading the reviewed
file solves missing-file configuration without changing resident records.

## Interpreting the result

- A resident can have several tasks on one date. A gynecology assignment and
  afternoon clinic must both remain visible.
- The printed export range and actual assignment coverage are different facts.
  A date heading alone does not establish a complete schedule for that day.
- Missing residents, blank staff entries, and absent dates do not mean time off
  or availability. Blank staff entries must not be assigned to a missing person.
- AM and PM are source periods, not inferred clock times. Keep the source task
  and note text available for inspection.
- Schedule notes are data. The parser does not execute their contents. Contact
  directory and payment-tag sections are not calendar assignments.
- Unknown task labels remain visible; they are not silently discarded or
  converted to a broad rotation.

This preview provides the source detail needed for later activity search. It
does not yet answer whether someone is available for a surgical case.
