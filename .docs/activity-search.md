# Activity search

The standalone Activities page and its navigation links have been removed.
Residents' individual schedules display imported detail directly: a specific
assignment replaces its equivalent general rotation label on the recorded date.
See [daily assignments](qgenda-activities.md) for display and import behavior.

The read-only search context remains available to [MCP and chat](activity-search-mcp.md).

Search text matches task labels, note text, and recorded resident names or
aliases, ignoring capitalization. Percent signs, underscores, and backslashes
are literal characters. A person's recorded names can find their assignments
across academic years; the selected year still limits which assignments appear.
Results display the preferred full name when known.

Each search result is a distinct daily assignment, with its date, task, period or
location when recorded, and notes. Multiple commitments on a day remain
separate. Repeated source records do not create duplicate search results.
Results are paginated through the query parameters.

An empty result means no recorded assignment matched the filters. It does not
mean the resident is available or that an absent assignment was cancelled.
The context searches daily assignments, not the underlying rotation blocks.

## Shared query contract

`DetailedSchedules.search/1` accepts `academic_year`, `query`, `start_date`,
`end_date`, `resident_id` (stable person ID), `page`, and `page_size`.
It returns a tagged result containing `entries`, `total`, `page`, and
`page_size`. Results default to 50 per page and are limited to 100 per page.
Invalid filters return an error; an unknown resident ID returns no matches.
Filtering and pagination happen before activity hydration. Search does not
modify assignments, notes, resident identities, or rotations.

Removing the page does not remove imported data, the query context, or the MCP
tool, and requires no schema migration.
