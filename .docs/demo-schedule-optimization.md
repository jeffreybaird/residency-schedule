# Demo schedule optimization specification

This specification prioritizes night and weekend workload fairness ahead of
educational quantities and sequencing. See the [evaluation report](demo-schedule-optimization-report.md)
for before-and-after results and the reproducible generation command.
This schedule is synthetic demonstration data, not clinically approved.

## Required behavior

Generate one globally compatible annual roster containing eight choices in each
PGY class, retaining all 32 position codes and invented names, the 2026–2027
calendar columns and event labels, and the exact existing FLOAT assignments.
The output remains `priv/demo/demo_schedule.csv`, consumed automatically by
`Release.seed_demo/0` in the existing demo deployment. No production schedule,
deployment process, or application scheduling semantics should change.

Equal quantities within a class are **soft objectives**. Clinical staffing,
assignment compatibility, vacation structure, fixed FLOAT, and the modeled
duty-hour limit are hard.
Historical per-period coverage is not a constraint.

## Provisional hard staffing specification

Derived from `ScheduleBuilder.Coverage` documentation and the existing
same-class overlap rule, rather than assuming its shortfall-only validator
enforces all of these requirements:

- Every non-FLOAT weekday period: exactly one resident per PGY on each of
  OB, ONC, GYN, AMB, and NF; exactly one PGY-2 resident on HHOB.
- Every weekend period: exactly four SWD and four SWN assignments in total.
  Together with same-class uniqueness, this implies one of each per PGY.
- At most one resident per PGY per period on any clinical rotation type.
  Vacation, post-call, blank time off, and FLOAT are not clinical rotations.
- Only valid PGY rotations and valid weekday/weekend placements. Every
  non-FLOAT weekday must contain an educational rotation or vacation; no
  empty weekday may improve an objective by deleting work.
- No incompatible overlapping working assignments after the applicable
  legacy date projections. Exact rest intervals cannot be inferred from
  these period assignments.

No complete minimum/maximum staffing specification for other Highland services
was found. Their existing annual class assignment budgets are retained below;
these are not evidence of clinically sufficient daily staffing.

## Preserve work while making quantities fair

Use these class-wide assignment budgets to prevent the optimizer from improving
fairness by deleting night/weekend work or transferring it to another PGY:

| Assignment | PGY-1 | PGY-2 | PGY-3 | PGY-4 | Basis |
| --- | ---: | ---: | ---: | ---: | --- |
| NF | 48 | 48 | 48 | 48 | Required weekday coverage |
| SWN | 48 | 48 | 48 | 48 | Required weekend coverage |
| SWD | 48 | 48 | 48 | 48 | Required weekend coverage |
| HNF | 16 | 16 | 24 | 24 | Existing class quantities |
| HWN | 28 | 16 | 24 | 24 | Existing class quantities |
| HWD | 28 | 40 | 23 | 25 | Existing class quantities |
| Vacation | 32 | 32 | 32 | 32 | Existing class quantities |

These are counts of service periods. The original fixture has some weekday
services in weekend columns and weekend services in weekday columns; retaining
period counts does not preserve its malformed duration-weighted hours.
Fairness must use projected shifts and worked weekends, not these cell counts.

Educational quantities use the historical median targets in `ResidentRoster`
as soft targets. Report all differences, both class totals and per-resident
distributions. PGY-1 HGYN's target of 56 periods is impossible with 48 active
weeks and same-class uniqueness. Its feasible maximum is 48, requiring at least
eight fewer HGYN periods than that target and compensating educational periods
elsewhere. This is an explicit educational-target deviation, not a relaxation
of staffing or a claim to preserve an approved curriculum.

## Vacation blocks and protected weekend

Every resident must receive exactly four weekday VAC assignments arranged as
two separate one-week blocks and one two-week block. The sorted lengths of
maximal runs are therefore `[1, 1, 2]`. Only weekday starts exactly seven days
apart join a run; another rotation, FLOAT, or a missing calendar week breaks it.
Intervening weekend columns do not split adjacent vacation weeks.

The Saturday and Sunday between the two weeks of the double block must contain
no assigned working shifts, including shifts projected from other source cells.
The generator leaves that weekend blank. This rule does not add protection to
the outer weekends of any vacation block. Existing staffing, class budgets,
FLOAT assignments, and duty-hour requirements remain hard.

## Objective priority

Optimize lexicographically, recording incumbent values and solver bounds/status
at each stage. Later stages must not worsen the attained earlier-stage values.
A time-limited feasible solution is not a proof of global optimality.

1. Total scheduled night shifts within each PGY: minimize the range first,
   then absolute deviations from the class average.
2. Weekend workload within each PGY: minimize ranges in scheduled weekend
   shifts and distinct weekends worked, then deviations from class averages.
3. Educational quantities: minimize target deviations and within-class
   differences. Use range and then deviations from the class average to assess
   inequality; report unavoidable target changes explicitly.
4. Sequencing: minimize the worst individual's undesirable-sequencing penalty,
   then overall penalties and within-class quality spread. Measure demanding
   concentration, night-to-day transitions, and recovery opportunities.
5. Meaningful diversity of vacation/night timing and rotation sequence, without
   worsening earlier objectives. Arbitrary cell differences are not a benefit.

For integer shift counts `x_i` in a class of eight, range is `max(x_i)-min(x_i)`.
An integer-scaled absolute deviation is `sum_i abs(8*x_i-sum_j x_j)`; dividing
by eight gives the sum of absolute deviations from the class average.

Night counts must count actual modeled night shifts, not NF/HNF weeks alone.
Weekend counts must include separately assigned weekend duties and relevant
Sunday-starting night duties. Friday-night duties belonging to a weekend must
be identified explicitly. A worked weekend is counted once even when several
shifts occur in it. Document boundary-weekend attribution consistently.

Specifically, count every Friday-night shift and every Saturday/Sunday shift,
including HNF Friday and Sunday and NF Sunday. Attribute these to the Saturday
of that calendar weekend. Include the leading Sunday duty projected from the
first annual NF/HNF assignment in annual workload fairness, even though that
Sunday precedes the CSV calendar; duty-hour windows remain inside the supplied
calendar. HNF therefore contributes two shifts on two distinct weekends.

The fixed assignment budgets imply night-shift totals of 460, 448, 504, and
504 across PGY-1 through PGY-4. Their minimum possible within-class ranges are
1, 0, 0, and 0. Weekend-shift totals are 356, 368, 358, and 362. Once night
fairness is optimal, their minimum ranges are **1, 0, 2, and 2**, not simply
the range implied by dividing each total by eight. For canonical assignments:

`night shifts - weekend shifts = 4*(NF periods + HNF periods) - 2*(SWD periods + HWD periods)`.

This difference is even. Every PGY-3/4 resident with 63 night shifts must have
an odd number of weekend shifts; the fractional class averages then force a
range of at least two. Seven residents with 45 weekend shifts and one with
43 (PGY-3) or 47 (PGY-4) attain those bounds. This illustrates the consequence
of prioritizing night fairness over weekend fairness.

## Duty-hour and projection contract

Use 12 hours per hospital shift and UG shift, eight per other working shift,
and zero for vacation, post-call, and time off. Include separately assigned
weekend duties. Check every rolling 28-day window contained in the annual
calendar, limiting evaluable windows to 320 hours. Any FLOAT involvement makes
a window incomplete, never a zero-hour compliance success.

The model must account for the importer's HNF Sunday–Friday and HWN Saturday
boundaries, and the effective legacy NF Sunday–Thursday and paired AMB/SWN
Monday–Thursday/Friday–Saturday boundaries. It must not double-count a clinical
day displaced by these projections. Existing application hours mappings differ
from this task's model and cannot be used unchanged to certify it.

Actual shift times, rest intervals, outside work, FLOAT duty, and neighboring
academic-year assignments are unavailable. Do not claim full ACGME compliance.

The prior cross-class overlap test counts FLOAT and absence markers. It remains
a synthetic compatibility convention; shared clinical work is reported
separately rather than imposing an undocumented all-pairs clinical rule.

## Original staffing shortfalls

These 17 service-period pairs violate the provisional documented minimums.
Counts are from the original synthetic CSV; weekend dates identify the start
of that weekend period.

| Period start | Service | Existing | Required |
| --- | --- | ---: | ---: |
| 2026-06-29 | OB | 3 | 4 |
| 2026-07-04 | SWD | 3 | 4 |
| 2026-07-04 | SWN | 3 | 4 |
| 2026-07-11 | SWD | 2 | 4 |
| 2026-07-18 | SWD | 2 | 4 |
| 2026-07-18 | SWN | 2 | 4 |
| 2026-07-25 | SWN | 2 | 4 |
| 2026-08-03 | ONC | 3 | 4 |
| 2026-08-08 | SWD | 3 | 4 |
| 2026-08-15 | SWD | 3 | 4 |
| 2026-08-15 | SWN | 3 | 4 |
| 2026-08-22 | SWD | 3 | 4 |
| 2026-09-05 | SWD | 3 | 4 |
| 2026-09-05 | SWN | 3 | 4 |
| 2026-09-12 | SWD | 3 | 4 |
| 2026-10-03 | SWD | 3 | 4 |
| 2026-11-28 | SWD | 3 | 4 |

## Validation and delivery

Automated tests must establish parsing without unknown labels, 32 synthetic
identities/eight per class, fixed calendar/FLOAT, staffing minima and maxima,
PGY and slot compatibility, annual work budgets, projected night/weekend counts,
daily-window modeled hours, vacation runs and their protected internal weekend,
and fixture import/name preservation/idempotence.
Test fairness metrics and priority ordering without turning equal individual
quotas into hard feasibility conditions. An infeasible solve or failed validation
must not overwrite the fixture or silently relax a constraint.

Retain the original synthetic fixture for reproducible before/after reporting.
Run relevant and full Elixir tests where practical and independently review the
result. Open a feature-branch PR only when all confirmed hard constraints pass.
Do not deploy or merge.
