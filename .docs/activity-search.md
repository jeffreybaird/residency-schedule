# Activity search

Open **Activities** in the navigation to search daily assignments. The page
defaults to the newest loaded academic year and searches its full date range.
Choose a resident or inclusive start and end dates to narrow the results.
Filters remain in the URL so the view can be bookmarked or shared with another
signed-in user.

Search text matches task labels, note text, and recorded resident names or
aliases, ignoring capitalization. Percent signs, underscores, and backslashes
are literal characters. A person's recorded names can find their assignments
across academic years; the selected year still limits which assignments appear.
Results display the preferred full name when known.

Each result is a distinct daily assignment, with its date, task, period or
location when recorded, and notes. Multiple commitments on a day remain
separate. Repeated source records do not create duplicate search results.
Results are paginated; use the page controls to inspect further matches.

An empty result means no recorded assignment matched the filters. It does not
mean the resident is available or that an absent assignment was cancelled.
The page searches daily assignments, not the underlying rotation blocks.

## Shared query contract

`DetailedSchedules.search/1` accepts `academic_year`, `query`, `start_date`,
`end_date`, `resident_id` (stable person ID), `page`, and `page_size`.
It returns a tagged result containing `entries`, `total`, `page`, and
`page_size`. Results default to 50 per page and are limited to 100 per page.
Invalid filters return an error; an unknown resident ID returns no matches.
Filtering and pagination happen before activity hydration. Search does not
modify assignments, notes, resident identities, or rotations.

This app change introduces no schema migration. MCP integration is a separate
change using the same query contract.
