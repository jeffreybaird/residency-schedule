# Indexed schedule cell construction

Cell construction looks up rotation coverage at each slot's start date. The
indexed implementation sorts only the requested start dates and each schedule's
rotation boundaries. It sweeps those dates while maintaining an ordered set of
active rotations, then restores the original slot order before the existing
grouping and annotation steps.

The active ordering includes each rotation's original list position, preserving
stable order when rotation types tie. Coverage includes both start and end dates.
The implementation preserves gaps, schedule boundaries, irregular and out-of-order
slots, legacy tuple-keyed lookups, grouped-cell identities, and detail tokens.
Adjacent cells with matching type/source-task keys still retain the first
rotation's identity when merged. Inputs remain immutable.

This avoids repeatedly scanning every rotation and sorting matches for every
slot. It does not expand long intervals into daily entries. Work still depends
on the number of overlapping rotations returned; a grid that displays many
concurrent rotations necessarily processes those results.

This change optimizes cold grid preparation. It does not change the shared cache,
database queries, rendering, or the size of the resulting HTML. Performance tests
use process-local reductions rather than wall-clock assertions, and a frozen
reference implementation verifies complete output equivalence.
