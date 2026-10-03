# Imported daily activities

QGenda activities describe what a resident is doing on a particular date or
period. They are stored separately from the existing rotation schedule. A
resident can therefore remain on gynecology while an afternoon clinic is shown
on the same day.

## Importing activities

Administrators use the QGenda form on `/admin/upload` to select an existing
academic year, upload a Calendar By Staff workbook, and optionally supply a
reviewed name crosswalk. See [the preview guide](qgenda-preview.md).

Review the matched people, assignment counts, date coverage, task details, and
notes before confirming. Confirmation saves matched assignments and their source
information. Unmatched or ambiguous staff are not attached to residents by guess.
Unknown task labels belonging to matched residents remain intact for inspection.
The import does not rename people or change the underlying rotation schedule.

## Resident display names

Resident pages, comparison selectors, calendar details, rotation coworker lists,
and schedule labels use the recorded full name when available. The same person
keeps that display name across academic years. When sources differ, the newest
academic year's name takes precedence, followed by the newest source record.
Directory-style `Last, First` names display as `First Last`.

People without a recorded full name keep their existing name; the app does not
guess a surname. These display choices do not modify roster names or identity
matching used by imports.

Matching is revalidated when saving. If the roster changed after previewing,
prepare a new preview rather than saving stale identity links. Only administrators
can confirm imports, and their access is rechecked on save. A preview with no
matched assignments cannot create an empty import batch.

Import dates must fall between June 1 of the selected start year and June 30 of
the following year. The June allowance accommodates orientation before July;
the check prevents saving an obviously different year's export into this roster.

## Viewing a day

The calendar's day details and the resident's daily activity view show imported
tasks and linked notes alongside rotations. Source labels preserve clinic names,
AM/PM, and call responsibilities. A task remains visible when the resident has
no base rotation recorded for that date.

For example, a resident may have both `SMH GYN R3 Day` and
`GOG Continuity Clinic PM`. Both belong in the day's details. The clinic must not
be collapsed into a generic GYN label.

No imported activities means that the app has no imported detail for that day.
It does not mean the resident is free, off duty, or available for surgery. This
milestone displays the source information; activity search and availability
rules are later milestones.

## Repeated and partial imports

Imports are additive. Reimporting an identical task for the same resident and
date does not create another activity. Source provenance is retained, and
different tasks on the same day stay separate.

Resolving previously unmatched people allows their assignments to be added from
the same workbook. An already imported source cell cannot be reassigned to a
different resident silently; that conflict rejects the transaction.

An export cannot establish that an absent task was cancelled: it may be filtered
or incomplete. Consequently, importing a new file does not delete tasks missing
from that file, assignments outside its date range, or other residents' detail.
If a later export changes a task label, the earlier activity can remain alongside
the new one. Explicit correction/removal and refresh comparison are outside this
milestone; do not interpret additive imports as authoritative replacement.

Missing residents and uncovered dates remain visible in the preview. Blank staff
entries cannot be attributed to whichever resident is missing from the export.

## Existing schedule operations

The activity store is independent of rotation edits. CSV year replacement must
not silently delete imported activities when it replaces schedule-resident rows;
the application protects this dependency. Year deletion is also blocked when
imported detail depends on the schedule. Review the resulting message before
attempting a full-year replacement or deletion. Partial rotation date updates
do not replace QGenda activities.

Keep real workbooks and crosswalks out of Git. This feature needs its database
migration before it is used on a deployed release. The normal deployment pipeline
runs migrations before restarting the service.
