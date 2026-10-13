# Schedule render update verification

## Accepted tests and red evidence

Seven regression cases use actual `Renderer.to_rendered/2` and `Diff.render/4`,
retain fingerprints/components, clear socket change tracking between operations,
and merge diffs to reconstruct client HTML. Assertions locate the grid's dynamic
subtree from the resolved static template rather than assuming a numeric path.

The contract preserves the initial nonempty grid, rows, slots, cell tokens,
148-pixel name column, modal focus behavior, and subsequent filtering. Unchanged
renders and academic-year changes under “All” must produce empty grid diffs.
Modal-only changes must omit the grid subtree. Filtered academic-year updates
still select the correct cohort. Successful deletion refreshes to the empty
state correctly.

Before source changes, the runner recorded **7 tests, 4 expected failures**:
unchanged render, “All” academic-year change, modal opening, and modal-clearing
schedule navigation all resent grid data. The three other behavior cases passed.
Evidence: `/tmp/schedule-render-updates-red.log`.

Independent review accepted test SHA-256
`2843dde8797735a574be17285b89495f3e4b11a504223ede3ad0805c03c51671`
before implementation.

The initial harness omitted the channel's private-event merge, which became
visible when the scroll test reached its unchanged push-event assertion after
the grid regression was fixed. The writer updated the harness to match Phoenix's
`clear_changed` → `render_private` → `clear_temp` sequence. Independent review
accepted the correction without weakening any assertion. Corrected harness hash:
`158009f5945188068c9ce5e31cf1eecd91d0e64ebf5572b9744a3133c80c72b4`.
The writer then extracted an equivalent helper to satisfy strict Credo; review
confirmed unchanged assertions. Final accepted test SHA-256:
`260fdd2cf361e66133d3a0b906c665ca694963226961162f2639b798bbc86710`.

## Baseline experiment

The four-year synthetic fixture contains 56 resident rows, 611 slots, and 13,437
grouped cells. The initial connected diff is 5,259,726 uncompressed JSON bytes.
Before the fix, modal opening resends 1,274,572 bytes and closing resends
1,272,107 bytes. A socket-only experiment persisting the width constant reduces
those values to 2,473 and 8 bytes respectively. This experiment changed no
application files; it isolated the render-time assign as a cause.

Baseline and diagnostic evidence:
`/tmp/schedule-render-diff-events.log` and
`/tmp/schedule-render-diff-constant-probe.log`. Measurements time actual LiveView
render/diff work; JSON encoding is separate and outside the render span. No
browser or network-transfer timing is inferred from JSON byte sizes.

## After-fix connected diff measurements

The actual after-fix render/diff benchmark confirms the initial connected diff
remains **5,259,726 bytes**. This change does not solve the reported initial
707 ms render or reduce the first grid payload.

Subsequent modal opening produces **2,473 bytes and 1,999 reductions**; closing
produces **8 bytes and 91 reductions**. Academic-year changes under “All” produce
an empty diff (**2 encoded JSON bytes and 76 reductions**), while retaining year
state for subsequent filtering. Schedule navigation still emits its private push
event; clearing a modal while navigating produces 57 bytes. Evidence:
`/tmp/schedule-render-diff-after-events.log`.

## Final checks

The authoritative runner recorded **211 doctests and 1,606 tests, zero failures**,
seed `238741` (`/tmp/schedule-render-updates-green-full.log`). The focused render
and existing ScheduleLive checks passed all 40 tests. After the final equivalent
helper extraction, the seven regression tests passed again
(`/tmp/schedule-render-updates-green-final.log`).

Compilation with warnings treated as errors, formatting, unused-dependency
verification, and all ten browser latency tests passed. Strict Credo checked
290 files and 2,400 modules/functions with no issues
(`/tmp/schedule-render-updates-green-credo-final.log`). The accepted test hash
was verified unchanged. The disposable benchmark database was dropped.

Fresh security evidence is recorded in
[schedule-render-updates-security-review.md](schedule-render-updates-security-review.md).
