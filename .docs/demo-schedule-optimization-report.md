# Optimized synthetic demo schedule — 2026–2027

The generated roster has 32 synthetic residents, eight per PGY, and satisfies
the [revised hard-constraint specification](demo-schedule-optimization.md).
The original 17 aggregate staffing shortfalls are eliminated. Night-shift
inequality falls substantially, and the worst illustrative sequencing penalty
falls from 90 to 58. Some component measures worsen; those tradeoffs are shown
below. This is demonstration data, not a clinically approved schedule.

The revised user instructions make individual rotation equality a soft
objective and permit changes to historical coverage. The former combination of
equal hard quotas and exact historical coverage was infeasible: for example,
PGY-3 had 47 ONC assignments, which cannot be divided equally among eight
residents. The delivered model retains hard staffing, compatibility, annual
night/weekend service budgets, fixed FLOAT, and modeled duty-hour limits.

## Evidence and reproducibility

The baseline is [the original synthetic fixture](../test/fixtures/demo_schedule_baseline.csv),
SHA-256 `58baeb7a81a0c76bde1ff08a36fea900812b38bbd3f99d1e6657eece97871a84`.
The generated [demo CSV](../priv/demo/demo_schedule.csv) has SHA-256
`6970cb153e982e56bee618136e3b05a95e7138db3ca4a6f50526a00a2e242750`.
The [machine-readable report](demo-schedule-optimization-metrics.json) contains
every resident's quantities, workload and quality measures, plus solver stages
and bounds. Its values were independently recomputed from the two CSVs.

The optimizer starts with a deterministic cyclic construction, improves worked
weekend fairness through valid local moves, repairs vacation blocks by compatible
whole-class week swaps, preserves those blocks during further balancing, then
runs CP-SAT stages in priority order. Earlier attained objectives cannot worsen
in later stages. Each class
has its own model because the specified staffing and fairness constraints
separate by PGY. Classwise worst-then-total quality refinement is a heuristic
for the corresponding global objective: it can miss a better global total
that would preserve the same global worst penalty.

The recorded OR-Tools 9.15.6755 run uses seed 2026, one worker, a deterministic
budget of 1.0 per stage and a 60-second emergency wall cap. The recorded 52
stages include 28 `OPTIMAL` and 24 `FEASIBLE` statuses; no wall cap was reached.
A feasible status is not an optimality
proof. The resulting fixture equals the constructive/local-search incumbent;
no additional CP-SAT quality improvement is claimed. Night-fairness and the
conditional weekend-shift bounds below also have independent arithmetic proofs.

An independent rerun with the patched dependencies produced the same CSV bytes,
before/after metrics, stage statuses and attained objective values. Some search
bounds and reported deterministic times differed; the solver trace is not
claimed to be byte-reproducible. The report preserves the solver's actual
diagnostic values.

Regenerate from the repository root in an isolated environment:

```sh
python3 -m venv /tmp/residency-demo-optimizer
/tmp/residency-demo-optimizer/bin/python -m pip install -r priv/demo/requirements.txt
/tmp/residency-demo-optimizer/bin/python priv/demo/generate_demo_schedule.py \
  --seed 2026 --deterministic-time 1 --seconds 60
python3 -m unittest discover -s test -p '*_test.py'
```

The generator defaults to the retained synthetic baseline and validates the
complete result before replacing the demo CSV. Unknown/time-limited solver
results may retain a valid incumbent; an infeasible or invalid model fails
without overwriting the output. If constructive vacation repair or its fixed-hint
check fails, the script reports that full-model feasibility remains unproven; it
does not label the overall scheduling problem infeasible. The old positional
real-template argument is
replaced by the optional `--baseline` interface, which rejects names outside the
established synthetic roster. Deployment continues importing the checked-in CSV
and does not need Python, OR-Tools or a manual upload.

## Hard constraints and modeled hours

| Measure | Original | Optimized |
| --- | ---: | ---: |
| Residents per PGY | 8 | 8 |
| Residents with VAC runs `[1,1,2]` | 29 | 32 |
| Required aggregate service-period staffing shortfalls | 17 | 0 |
| Same-class clinical label collisions | 0 | 0 |
| Fixed FLOAT assignments | 128 | 128, unchanged |
| Existing cross-class pairing convention: missing pairs | 0 of 384 | 0 of 384 |
| Maximum evaluable rolling 28-day hours | 300 | 320 |
| Maximum modeled weekly average over those windows | 75 | 80 |
| Evaluable resident/windows | 9,024 | 9,024 |
| FLOAT-incomplete resident/windows | 1,760 | 1,760 |

The final validator reports no violations of the revised hard constraints.
It checks per-PGY staffing, service budgets, eligible rotations and slot types,
literal FLOAT labels, invented names, VAC runs `[1,1,2]` and their protected
internal weekend, projected working-date overlaps, and
every evaluable 28-day window. The CSV calendar and all synthetic position/name
identities are preserved. Clinical services have at most one resident of a
given class per period; absence markers are exempt.

The hours model assigns 12 hours to OB, ONC, GYN, HGYN, HHOB, NF, HNF, SWD,
SWN, HWD, HWN and UG; other working assignments receive eight hours; vacation,
post-call and blank time off receive zero. It counts separately assigned weekend
duty. It applies the application's legacy projections: NF starts Sunday through
Thursday, HNF Sunday through Friday, HWN is one start-date shift, and paired
AMB/SWN becomes Monday–Thursday daytime plus Friday–Saturday nights. The model
uses all calendar-contained daily rolling 28-day windows and a 320-hour limit.
Any FLOAT date makes a window incomplete.

The maximum rises by 20 modeled hours from the original and reaches the limit. This
does not establish full ACGME compliance: actual shift timing, required rest,
outside duties, FLOAT work and neighboring academic-year duties are unavailable.
Other Highland services lack a complete clinically approved daily staffing
specification; their preserved annual budgets do not prove adequate coverage.

## Night and weekend fairness

All ranges below are per resident within a PGY. A night shift is a projected
working shift labeled NF, HNF, SWN or HWN. Weekend shifts include Saturday and
Sunday work and every Friday-night shift, including HNF Friday. A worked
weekend is one distinct Saturday-associated weekend regardless of how many
shifts occur in it. Thus one HNF week touches two weekends. Projected leading
Sunday shifts count toward annual workload even when they precede the first
CSV date; duty-hour windows retain the original calendar boundaries.

| PGY | Night shifts, before → after | Weekend shifts, before → after | Distinct weekends worked, before → after |
| --- | --- | --- | --- |
| 1 | 57–61 → 57–58 | 44–46 → 44–45 | 26–27 → 25–25 |
| 2 | 56–56 → 56–56 | 46–46 → 46–46 | 26–27 → 25–25 |
| 3 | 63–66 → 63–63 | 45–46 → 43–45 | 27–28 → 24–24 |
| 4 | 63–69 → 63–63 | 45–47 → 45–47 | 27–28 → 26–26 |

After correction of misplaced baseline assignments, class night totals are
460, 448, 504 and 504. Divisibility by eight proves minimum night ranges of
1, 0, 0 and 0, all attained. Class weekend-shift totals are 356, 368, 358 and
362. For each generated resident, with `N` night shifts and `W` weekend shifts,

`N - W = 4*(NF + HNF periods) - 2*(SWD + HWD periods)`.

Consequently `N` and `W` have the same parity. Once PGY-3 and PGY-4 attain
63 nights each, their weekend counts must be odd. Their class totals require
minimum weekend ranges of two, achieved by seven counts of 45 plus one of 43
or 47 respectively. The attained conditional minimum weekend ranges are
therefore 1, 0, 2 and 2. PGY-3's range increase is a consequence of prioritizing
night fairness, not a hidden waiver of the objective order.

For counts `x_i`, within-class range is `max(x_i)-min(x_i)`. The scaled absolute
deviation is `sum_i abs(8*x_i-sum_j x_j)`; divide by eight for ordinary absolute
deviation from the mean. Sum these metrics across PGYs. Total night range falls
13→1 and scaled deviation 232→32. Weekend-shift range remains 5, while its
scaled deviation rises 82→88. Worked-weekend range falls 4→0 and scaled
deviation 98→0. These distinguish improved priority metrics from measures that
do not improve. Zero worked-weekend inequality is optimal for that metric;
the objective does not minimize the total number of weekends worked.

## Rotation quantities

Educational rotation equality is soft, but all eight residents within each
class attain equal weekday educational counts in the result. Annual class
night/weekend budgets remain hard. This preserves service-period quantities,
not the malformed baseline's duration-weighted workload: the original placed
some weekend labels in five-day periods and some weekday labels in weekends.
The target deviation is the sum, over educational labels and PGYs, of the
absolute difference between the class count and eight times the historical
per-resident target. It improves from 50 to 16.

PGY-1 HGYN's historical target is 56 periods. With 48 active weekday periods
and at most one PGY-1 resident on HGYN per period, at most 48 are feasible.
Eight periods are replaced with US. This produces the unavoidable minimum
total target deviation of 16: eight below the HGYN target and eight above the
US target. Each PGY-1 resident receives six HGYN and four US periods rather
than historical targets of seven and three. This is an explicitly permitted
soft-target change, not preservation of an approved curriculum.

The following table lists every changed class quota or literal duration.
Cells count all dated source columns, including historically misplaced cells.
Days are inclusive literal CSV spans, not projected shifts or duty hours.
All omitted label/class combinations are unchanged. Full per-position values
are in the JSON report.

| PGY | Label | Dated cells, before → after | Literal days, before → after |
| --- | --- | --- | --- |
| 1 | HGYN | 56 → 48 | 244 → 240 |
| 1 | HWD | 28 → 28 | 65 → 56 |
| 1 | HWN | 28 → 28 | 59 → 56 |
| 1 | P | 79 → 0 | 158 → 0 |
| 1 | SWD | 48 → 48 | 111 → 96 |
| 1 | SWN | 48 → 48 | 105 → 96 |
| 1 | US | 24 → 32 | 120 → 160 |
| 2 | P | 78 → 0 | 156 → 0 |
| 3 | ELECTIVE | 32 → 32 | 154 → 160 |
| 3 | HGYN | 25 → 24 | 125 → 120 |
| 3 | OB | 48 → 48 | 237 → 240 |
| 3 | ONC | 47 → 48 | 235 → 240 |
| 3 | P | 94 → 0 | 188 → 0 |
| 3 | SWD | 49 → 48 | 104 → 96 |
| 3 | SWN | 48 → 48 | 99 → 96 |
| 4 | ELECTIVE | 32 → 32 | 151 → 160 |
| 4 | HGYN | 48 → 48 | 222 → 240 |
| 4 | HWD | 25 → 25 | 53 → 50 |
| 4 | P | 94 → 0 | 188 → 0 |
| 4 | SWD | 47 → 48 | 109 → 96 |
| 4 | SWN | 48 → 48 | 105 → 96 |

The generated source represents unassigned weekends as blank time off instead
of explicit P markers. Both contribute zero modeled hours; the application's
existing NF projection still supplies its derived post-call dates. Every
resident retains four vacation periods and the four fixed FLOAT periods. The
vacations now form two single weeks and one double week; its internal Saturday
and Sunday have no projected working shifts. Outer weekends remain governed by
the existing scheduling rules.

## Sequencing quality and diversity

The illustrative penalty is `3*demanding_triples + 2*night_to_day - recovery`.
These weights are explicit demo design choices, not clinically validated fatigue
weights. A demanding triple is three consecutive weekly periods carrying
12-hour labels; triples overlap and FLOAT breaks a sequence. A night-to-day
adjacency is an NF/HNF weekday period followed by a working, non-night weekday
period. It ignores intervening weekend recovery and is not evidence of an unsafe
shift transition. A recovery opportunity is a demanding period followed by a
vacation period. These metrics are subordinate to workload and educational
fairness in the revised priority order.

| PGY | Penalty range, before → after | Mean, before → after | Population SD, before → after |
| --- | --- | --- | --- |
| 1 | 57–68 → 30–47 | 62.000 → 40.875 | 3.937 → 5.231 |
| 2 | 57–84 → 49–58 | 67.375 → 54.500 | 8.030 → 2.693 |
| 3 | 61–81 → 31–57 | 71.500 → 45.500 | 7.176 → 8.246 |
| 4 | 59–90 → 33–51 | 69.625 → 45.625 | 9.949 → 5.872 |

| Component, across all residents | Original | Optimized |
| --- | ---: | ---: |
| Demanding triples | 651 | 408 |
| Night-to-day adjacencies | 145 | 167 |
| Recovery-to-vacation opportunities | 79 | 66 |
| Worst individual penalty | 90 | 58 |
| Total penalty | 2,164 | 1,492 |

Demanding concentration falls enough to improve the composite penalty despite
more night-to-day adjacencies and fewer recovery-to-vacation opportunities.
The outcome should not be described as improving every component.

Each PGY has eight distinct vacation timing signatures and eight distinct NF/HNF
timing signatures both before and after. A signature is the set of period indices
carrying that assignment. The final diversity stage spreads vacation timing
without worsening attained earlier objectives. A pairwise per-slot NF/HNF
difference sum would be constant under fixed totals and same-class uniqueness;
it is not presented as an optimized night-diversity metric. Neither eight distinct
signatures nor this construction proves maximally diverse rotation sequencing.

The existing cross-class overlap test counts FLOAT and absence markers, so all
384 cross-class pairs satisfy it in both fixtures. It is a synthetic convention.
A separate diagnostic excluding absence/FLOAT labels finds 54 original and 117
optimized pairs without a shared working label in the same source period.
Clinical coworker diversity therefore worsens and is not claimed as an improvement;
an all-pairs clinical pairing mandate was not established by the repository.

## Change from the preceding optimized fixture

The new hard vacation requirement replaces the previous optimized fixture
(SHA-256 `505a80a463b42a520c99edf5274d753be3f38aaac5466d9f84b14edd83117208`,
available at `b5a8311:priv/demo/demo_schedule.csv`). That fixture had 31 residents with four single
vacation weeks and only one with the requested block pattern. All 32 now have
maximal runs `[1,1,2]`, and all double blocks have a work-free internal weekend.
Every resident's dated-cell rotation quantities are unchanged from that fixture;
class budgets, synthetic identities, calendar and FLOAT assignments also remain
unchanged. This is a sequencing change, not redistribution of service quantities.

| Measure | Previous optimized | Current protected vacations |
| --- | ---: | ---: |
| Residents with VAC runs `[1,1,2]` | 1 | 32 |
| Staffing shortfalls | 0 | 0 |
| Maximum evaluable 28-day hours | 312 | 320 |
| Demanding triples | 275 | 408 |
| Night-to-day adjacencies | 192 | 167 |
| Recovery-to-vacation opportunities | 73 | 66 |
| Worst individual penalty | 45 | 58 |
| Total sequencing penalty | 1,136 | 1,492 |
| Sum of within-PGY worked-weekend ranges | 1 | 0 |
| Cross-class pairs without shared working label | 270 | 117 |

Night-shift and weekend-shift fairness are unchanged. Distinct weekends worked
per resident change from 23–24 to 25 in PGY-1, 23 to 25 in PGY-2, stay 24 in
PGY-3, and change from 24 to 26 in PGY-4. Equality therefore improves while the
number of weekends touched increases in three classes. Vacation and night-float
timing still each provide eight distinct signatures per PGY. The increased
sequencing penalty is an observed tradeoff of this feasible construction, not a
proof that every schedule satisfying the new rule must have that penalty.

## Verification and security status

Current vacation-change verification:

- **40 Python tests, zero failures**, 34.795 seconds. The runner captured the
  expected failing tests before implementation, then independently regenerated
  the final CSV byte for byte. Before/after metrics, hard-constraint results,
  generation parameters and attained objective values matched; no wall cap was
  reached. A fresh evaluator also matched the checked-in JSON.
- Relevant Elixir tests: **47 tests, zero failures**, including the new imported
  vacation-block and protected-weekend check. Format checking and compilation
  with warnings treated as errors passed.
- Full Elixir suite: **217 doctests, 1,727 tests, zero failures**, 116.0 seconds.
- Earlier implementation validation passed 49 release-artifact tests (10,666
  assertions) and 43 database-recovery tests (642 assertions). Those deployment
  tests and workflow files are unchanged by this vacation-only update. Automatic
  demo seeding remains unchanged.

Accepted test hashes are
`aae1bd2033378fc87ccf033160607b6256dc192e74ef9065e610830e4559c9d7`
for the Python contract and
`d1890656beb0621f7137bd2ba8800e79e6f321b2f81ad5fc2cc3218ad04778a5`
for the Elixir demo tests. The corrected Elixir test reads the literal header
dates and uses the actual importer plus `StrongNightBoundaries.project/3`,
independently checking the Python duty projection against application behavior.

The initial Python dependency audit identified protobuf 6.31.1,
**GHSA-7gcm-g887-7qv7 / CVE-2026-0994 / PYSEC-2026-1805**: deeply nested `Any`
objects passed to `ParseDict` can cause recursion denial of service. Patched
versions include 6.33.5 and 5.29.6. This optimizer builds CP-SAT objects rather
than parsing untrusted JSON into protobuf. Nevertheless, the requirements now
pin **OR-Tools 9.15.6755 and protobuf 6.33.5**. OR-Tools 9.14 required protobuf
below 6.32, so upgrading OR-Tools was necessary to install the compatible patch.

On **2026-10-18**, current PyPI package-version JSON vulnerability records
(OSV/PYSEC metadata) reported no advisories for the patched pair and their seven
installed transitive dependencies: absl-py 2.5.1, immutabledict 4.3.1,
numpy 2.5.4, pandas 3.0.6, python-dateutil 2.9.0.post0, six 1.17.0 and
typing_extensions 4.16.0. `pip check` passed. Local evidence is
`/tmp/demo-vacation-security-audit.json`. This is a package-metadata advisory
check, not a comprehensive runtime-security assessment.

The **2026-10-18** `mix hex.audit` also exited zero with no retired or advisory packages
reported. Independent runtime inspection found Elixir 1.19.5, OTP 28.5.0.7 and
ERTS 16.4.0.6, meeting the repository's previously documented patched OTP
baseline. Current complete OTP, operating-system and Ruby advisory coverage,
vendored code, unknown vulnerabilities and actual production runtime remain
unverified. No claim is made that package checks establish production safety.

The reviewed agent audit has 325 entries and 134 entries with ambiguous
violation attribution, with no exclusive violation finding.
Live hook activation is unverified; role-owned edits, accepted hashes and final
diff inspection provide the ownership evidence for this task. No deployment or
merge is authorized.
