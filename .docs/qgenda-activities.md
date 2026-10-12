# Daily assignments

Daily assignments describe what a resident is doing on a particular date or
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

The calendar's day view and day-detail dialog group each resident's rotations,
daily assignments, and notes together. Additional clinic and duty details remain
visible except for the reviewed duplicate labels below. A task remains visible
when the resident has no base rotation recorded for that date.

Each rotation group has one heading and a compact resident list. Daily tasks
appear in parentheses beside the resident's name; residents without tasks have
no assignment placeholder. Notes and coverage details remain attached to the
resident, without duplicate rotation badges or individual bordered cards. Calendar
day details omit the resident's schedule designation (`Rn-n`).
Assignments that only repeat their matching rotation heading are omitted from
the parentheses. These exact labels are recognized:

| Assignment | Matching rotation group |
| --- | --- |
| `Ambulatory R1`–`R4` | Ambulatory |
| `Elective R3`–`R4` | Elective |
| `HH GYN ONC R1`–`R4` | Oncology |
| `HH GYN R1`–`R4` | Gynecology – Highland |
| `REI Resident` | Reproductive Endocrinology & Infertility |
| `Urogyn Resident` | Uro-Gynecology |
| `Swing Resident` | Swing Shift |
| `Ultrasound` | Ultrasound |
| `Vacation` | Vacation |
| `Post-Call` | Post Call |
| `SMH GYN R2 Day`, `SMH GYN R3 Day` | Gynecology – Strong Memorial |
| `SMH Gynecology Chief On Call Day`, `SMH Gynecology Intern On Call Day` | Gynecology – Strong Memorial or Weekend Days – Strong |
| `SMH Gynecology Chief On Call Night`, `SMH Gynecology Intern On Call Night` | Night Float – Strong or Weekend Nights – Strong |
| `SMH Obstetrics Resident 1st Contact Day`–`4th Contact Day` | Obstetrics – Strong or Weekend Days – Strong |
| `SMH Obstetrics Resident 1st Contact Night`–`4th Contact Night` | Night Float – Strong or Weekend Nights – Strong |
| `HH Weekend 2nd Call`, `HH Weekend 3rd Call`, `HH Weekend Extra` | Weekend Days – Highland |
| `HH Nights 2nd Call`, `HH Nights 3rd Call`, `HH Nights Extra` | Weekend Nights – Highland or Night Float – Highland |

These SMH labels were reviewed as restatements of the listed rotation headings.
Matching uses the existing heading, without inferring a service from the weekday.
Other clinic, timing, and call labels remain visible. Matching is exact: additional
suffixes or unlisted tasks are not hidden by a prefix or keyword match. Notes and
original assignments remain stored; notes remain visible even when their task
label is omitted. Assignments appear normally outside their matching group. A
resident with only a redundant assignment has no empty parentheses.

Highland weekend-day and night-call labels use the equivalences above. A Highland
night assignment that matches an existing Night Float – Highland or Weekend
Nights – Highland entry uses that group. It does not create a second weekend-night
group solely because its source date is Saturday. A Saturday night assignment
without a matching base rotation retains the Weekend Nights – Highland calendar
fallback, including its service filter and month/week summaries. The same resident
counts once in a service when both a base rotation and imported assignment exist.
These display rules preserve source dates and tasks without creating base rotations.

On Fridays, an Ambulatory resident with an exact SMH Obstetrics Resident 1st–4th
Contact Night assignment is displayed as Night Float – Strong. Any one such
assignment makes the usual Strong Night Float team Post Call for that date in the
same schedule. Explicit Strong night assignments and coverage overrides take
precedence. This derived correction applies across schedule views, coworker
queries, shift counts, assistant answers, and calendar exports; it does not change
stored rotations or imported activities. See the
[Friday correction contract and verification](friday-night-float-verification.md).

On a resident page, open a rotation to see that resident's assignments and notes
for the rotation's date range, alongside the existing coworker information. The
dialog identifies the resident and rotation dates and closes with Escape. The
resident's date selector also provides access to assignments on days without a
rotation.

On a resident's chronological schedule, the specific imported task replaces its
equivalent general rotation label on matching dates. A rotation span splits where
the recorded tasks change; dates without matching detail retain their general
label. The specific row keeps the original service filter, coverage information,
and coworker lookup for its displayed dates. Task notes remain visible, and a
matched task is not repeated in a separate daily-assignment row. The selected-date
panel similarly omits a general base-rotation line when the equivalent specific
task is shown.

Other daily assignments remain visible, including clinics and duties without a
matching base rotation. Multiple tasks on one date remain together with their
notes. Dates with recorded assignments are excluded from generated OFF rows; the
remaining dates in an OFF span remain visible. Unmatched daily assignments retain
their own service filter and literal source dates. Shift statistics continue to
count days in the base rotation schedule without inferring shifts or hours from
task labels. Stored rotations and imported assignments are not rewritten.

Rotation pills in the schedule grid open the same daily assignment details.
The dialog follows the dates shown by that pill, including adjacent blocks
combined into one span. Different services and academic years remain separate.
Pills are keyboard-accessible buttons; Escape, the close button, or the backdrop
closes the dialog. Changing the displayed cohort or year closes stale details.

These schedule views use ordinary scheduling language. They do not show the
import provider, workbook coordinates, or batch metadata. Administrators can
still review source information during import.

For example, a resident may have both `SMH GYN R3 Day` and
`GOG Continuity Clinic PM`. Both belong in the day's details. The clinic must not
be collapsed into a generic GYN label.

The resident's daily detail panel says "No daily assignments recorded" when
empty; the calendar's compact list omits that message. Missing assignments do
not establish that the resident is free, off duty, or available for surgery.
Activity search and availability rules are separate capabilities.

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
