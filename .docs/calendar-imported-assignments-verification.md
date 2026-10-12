# Imported calendar assignment verification

## Production data correction

On October 12, 2026, the deployed release `d90c5a2` contained zero detailed
activities and zero QGenda import batches. The earlier display change could not
show assignments that had never been saved to production.

After explicit user authorization, the existing workbook and reviewed resident
crosswalk were transferred to a private temporary directory on the application
server. The application's preview matched 7,646 assignments for 31 people, with
807 unmatched assignments excluded. Preview validation reported no warnings.
The normal `DetailedSchedules.commit/2` transaction saved the matched assignments
as import batch 1. A subsequent read confirmed the reported October 10 night-call
assignment, and the deployed resident LiveView loaded its timeline entry.
Temporary input files were removed after verification. No private source workbook,
crosswalk, or roster is included in this change.

## Calendar changes

The user confirmed **Weekend Nights – Highland** for the reported Saturday
assignment. Calendar classification is restricted to the exact Saturday labels
`HH Nights 2nd Call`, `HH Nights 3rd Call`, and `HH Nights Extra`. It preserves
literal dates and responsibilities without creating base rotations.

The user also reported redundant rotation names in the compact assignment list.
The initial change omitted `Ambulatory R1`–`R4` and `Elective R3`–`R4` within
their matching rotation groups. The user subsequently reviewed and approved the
additional exact mappings listed in [the activity guide](qgenda-activities.md),
including SMH resident gynecology and obstetrics labels. Matching headings now
omit those reviewed labels from the parentheses. Other duties and all notes
remain visible; source records remain unchanged.

## Verification

The test writer, runner, implementer, and independent reviewer followed the
required test-first workflow. The reviewer additionally caught and required
regression tests for preservation of existing coverage counts and unclassified
assignment visibility under service filters. Corrected source and the frozen
tests were accepted independently.

See the runner's [red and green verification record](calendar-highland-assignments-verification.md)
for exact commands, accepted test hashes, results, and security scope.
