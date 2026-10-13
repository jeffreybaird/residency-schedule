# Schedule render update tracking

The schedule renderer previously assigned `name_col_px` while constructing the
template. That value did not persist on the LiveView socket, so each render
marked it changed again. Grid markup depends on this width, causing unrelated
modal updates to revisit and transmit grid data.

A second unnecessary dependency connected the full resident-group comprehension
to the viewed academic year. With the “All” filter selected, the grouping function
returns the same residents regardless of that year. Scrolling across years still
caused a large grid diff.

The fix stores the immutable width at mount and assigns grouped visible residents
when their inputs change. Normal LiveView assign equality preserves unchanged
groups. The template depends on those groups directly. Viewed year remains in
socket state for subsequent residency-year filtering and modal lookup. Reloading
schedules still resets the filter and recomputes groups.

This preserves the initial full grid, continuous multi-year scrolling, event
payloads, detail identities, modal focus behavior, and access controls. It does
not virtualize columns or change the grid's HTML size. Initial rendering remains
a separate cost: the four-year synthetic fixture produces approximately 5.26 MB
of uncompressed initial LiveView diff JSON.

## Diagnosis

Measurements use `Phoenix.LiveView.Renderer.to_rendered/2` followed by actual
`Phoenix.LiveView.Diff.render/4`, retaining fingerprints/components and clearing
socket change tracking between updates. JSON encoding is measured separately;
it is outside the existing LiveView render telemetry span. Payload sizes are
uncompressed JSON bytes, not network-transfer or browser timings.

Before application changes, a socket-only experiment persisting the width
reduced modal-open diff size from 1,274,572 to 2,473 bytes and modal-close from
1,272,107 to 8 bytes. A forced unchanged render fell from approximately 1.27 MB
to an empty diff. Academic-year changes under “All” still generated approximately
1.27 MB until the grouping dependency was addressed.

The browser's `YearTracker` hook separately scans header geometry on scroll.
That browser work cannot explain time inside a server render span and is not
modified by this fix.
