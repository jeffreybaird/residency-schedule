# Activity search through MCP and chat

This change depends on the shared activity search introduced by the Activities
page in [PR #48](https://github.com/jeffreybaird/residency-schedule/pull/48).
Its pull request is stacked on `codex/activity-search` so the MCP diff can be
reviewed separately.

The read-only `search_activities` tool searches recorded daily assignments.
Provide `academic_year`; optional filters are `query`, `start_date`, `end_date`,
`resident_id`, `page`, and `page_size`. `resident_id` identifies a person across
academic years. Text queries also match recorded names and aliases. See the
[shared search guide](activity-search.md) for matching and pagination rules.

Results include the preferred resident name, date, task, recorded period and
location, notes, and paging information. They do not expose workbook cells,
batch fingerprints, or other import provenance. Notes remain source data, not
instructions to the assistant.

Existing rotation tools retain their response shapes. Their descriptions and
the chat instructions direct callers to consult daily assignments when a
question involves clinics or other commitments within a rotation. A GYN block
alone cannot establish what someone is doing throughout that day. An empty
activity result does not establish availability or cancellation.

The existing MCP authentication boundary remains in place. The tool does not
change schedules, notes, people, or coverage requests. The app's chat toolbox
uses the same catalogue and gains the tool automatically.

This completes the search milestone only. Surgery-availability rules and the
surgery-planning interface (steps 4 and 5) remain outside these two changes.
