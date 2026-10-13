# Schedule date window

## Accepted behavior

The schedule keeps one continuous horizontal timeline and its complete cached
schedule data. Only the date window around the viewport is materialized into
headers and rotation cells. Calendar behavior and authorization are unchanged.

Each date slot occupies exactly 80 CSS pixels beside the 148-pixel sticky name
column. Leading and trailing spacer columns preserve the timeline's full width.
Headers wrap inside their fixed width. Rotation labels may truncate visually;
their accessible label and detail dialog preserve the complete assignment.

The initial window contains at most 40 slots, starting eight slots before today
when today belongs to a slot, otherwise at the timeline's beginning. The client
requests the visible dates plus an eight-slot buffer on either side. The server
clamps requests to the dataset and a maximum of 128 slots. Normal desktop and
mobile requests remain much smaller than that maximum.

The fixed `update_window` event carries a start, count, and first-visible slot
index. The server derives the viewed academic year from the first-visible slot;
it does not trust a client-supplied year for this event. Malformed input must not
crash the LiveView or expand the render beyond the bound.

Merged cells are intersected with the requested slot interval. Clipping changes
only their displayed colspan, preserving the original rotation object, cell
token, and full detail dates. Nil gaps, overlapping assignments, and schedule
boundaries retain their existing meaning. Full cached rows remain available to
detail lookup and subsequent windows.

The hook uses compact metadata for the complete timeline, rather than searching
only materialized headers, to update year indicators, schedule pills, and cohort
visibility. Scroll and resize work is coalesced. At most one window request is
in flight, with only the latest pending viewport retained. Ordinary patches do
not change scroll position. A large jump may temporarily show an empty spacer
while the requested data arrives; cells must never appear under incorrect dates.

Schedule pills can jump to dates outside the current window. Closing a detail
dialog restores its original opener window before focusing the opener, with a
focusable scroll-region fallback when the opener is no longer available. This
restoration applies only to dialog close, not ordinary window updates. Filters,
deletion, empty states, guided tours, and repeated navigation remain supported.

## Trace interpretation

The existing `app.rows.count`, `app.slots.count`, `app.cells.count`, and
`app.cohorts.count` continue to describe available schedule data. Their
`app.rendered.*` counterparts describe the materialized window. A cell count is
the number of merged cell groups, excluding spacer cells, rather than the number
of row-by-slot intersections. These are workload counts; an unchanged LiveView
diff may skip visiting some or all of those cells.

`update_window` is a fixed permitted event label, and
`app.render.changed.schedule_window` indicates that the projection changed. Slot
indices, dates, event payloads, resident identifiers, and labels are not exported
as trace attributes. The complete render diagnostic set remains bounded at
39 attributes within the existing 64-attribute SDK limit.

## Verification requirements

Tests independently check clipping against the original full grid, bounded
server inputs, exact column coverage, detail identity, actual LiveView diffs,
and JavaScript geometry, acknowledgments, resize, and teardown. Browser checks
cover desktop, mobile, and wide viewports with an isolated synthetic database.
The same four-year fixture is measured before and after the change using actual
Phoenix rendering and serialization. Timing and payload results belong in the
verification record; reduced initial payload does not imply a measured
production latency guarantee.
