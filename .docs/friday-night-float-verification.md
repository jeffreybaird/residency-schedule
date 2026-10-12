# Friday Ambulatory night coverage

## Accepted domain rule

On a Friday, an Ambulatory resident assigned an exact `SMH Obstetrics Resident
1st Contact Night`, `2nd Contact Night`, `3rd Contact Night`, or `4th Contact Night`
works Night Float – Strong. Any one qualifying assignment triggers the correction
for that schedule and date. The usual Strong Night Float team is Post Call that
Friday. Ambulatory residents without a qualifying assignment remain Ambulatory.

The derived correction preserves explicitly assigned Strong night duties and
approved coverage overrides. It does not infer replacements on other weekdays,
at Highland, or in another academic-year schedule. Imported activities and stored
rotation records remain unchanged; the correction splits displayed spans at the
affected date. Editor data continues to represent stored rotations.

Read views, resident shift counts, coworker queries, assistant answers, and calendar
exports must agree. Post Call does not count as a working shift. A derived Friday
night exports from Friday evening to Saturday morning without moving legacy
night events. When the following Saturday's Strong weekend-night event represents
that same interval, the export includes the interval once.

## Verification

Authoritative core red command:

```sh
MIX_ENV=test mix test test/residency_schedule_web/live/friday_night_float_test.exs --seed 0
```

Exit 2: **11 tests, 10 failures**, 0.6 seconds. The qualification guards already
passed; the new projection and downstream read surfaces failed as expected.
Log: `/tmp/friday-night-float-red.log`.
Initial formatted contract SHA-256:
`427199d8db40b83f951e005ec3ca7c52997405f24f034877e27673823979c0df`.

The reviewer accepted the core contract before implementation. The read-only grid
regression and pure projection doctest registration were added after implementation
and independently accepted; no grid-specific red run is claimed. The first focused
implementation run had 1 doctest, 12 tests and 1 failure: an Assistant assertion
referenced `person_id`, which is not in that public response. The writer corrected
it to an exact singleton of existing name, position and rotation fields; reviewer
renewed acceptance without changing the intended projection behavior.

Final accepted SHA-256, verified unchanged after final execution:

```text
255c5c26bc782ac6926fa6dac02bb56b8ce4844a103fd07aed2cb39f81780dd1  test/residency_schedule_web/live/friday_night_float_test.exs
```

The runner makes no source/test edits. Local runtime remains Elixir 1.19.5 /
OTP 29.0.1; Mix requires native escalation for local sockets and the test database.

### Green checks

Owners ran scoped formatting before read-only runner checks.

- Focused command above: exit 0; **1 doctest, 12 tests, 0 failures**, 0.7 seconds.
  Log: `/tmp/friday-night-float-focused-final.log`.
- `MIX_ENV=test mix format --check-formatted`: exit 0.
- `MIX_ENV=test mix compile --warnings-as-errors`: exit 0.
- `MIX_ENV=test mix deps.unlock --check-unused`: exit 0.
- First Credo run found one source alias-order offense. The implementer corrected
  and formatted it; final `MIX_ENV=test mix credo --strict`: exit 0, 272 files,
  2,221 modules/functions, no issues. Log: `/tmp/friday-night-float-checks-final.log`.
- `MIX_ENV=test mix test --seed 298741`: exit 0; **201 doctests, 1,535 tests,
  0 failures**, 42.0 seconds. Includes rotations, coverage, Assistant, calendar,
  resident, read-only schedule and ICalendar regressions.
  Log: `/tmp/friday-night-float-full-green.log`. The private-data sentinel is
  intentional test output.
- `git diff --check`: exit 0.

No JavaScript/assets changed; no redundant JavaScript or asset build was run.

## Security scope

The existing [October 12 security review](qgenda-oct12-security-review.md)
documents dependency audit evidence and unresolved local OTP runtime advisories.
Final review must verify its applicability to the completed diff. Test execution
does not verify the production runtime.

## Independent review

The reviewer inspected the complete source diff, the pure projection module,
downstream readers, and the frozen test contract. No implementation blocker was
found. Final acceptance follows the runner's passing checks above: 201 doctests
and 1,535 tests, zero failures. The accepted test hash remains unchanged. The
final alias-order correction and range-query documentation clarification were
also reviewed; neither changes behavior.

- Exact Friday contact-night evidence is scoped by schedule identity and applied
  before display filters. Explicit Strong night assignments and approved override
  participants retain precedence. Raw query and editing APIs remain unchanged;
  projection updates only in-memory structs.
- Resident views, the read-only grid, calendar, coworker queries, Assistant, and
  effective-segment exports share the projection. Coworker comparisons reuse a
  schedule's projected segments rather than reloading the entire schedule for
  every pair. The range projection's only consumer is the calendar, which reads
  dates in the requested window.
- The virtual source date reaches exported segments. Derived Friday duty runs
  Friday 18:00 to Saturday 06:00; legacy timing remains intact. Covered segments
  are removed before exact Strong weekend-night deduplication. Thursday daytime
  and simultaneous Highland duties remain represented.
- The grid regression and executable happy-path doctest were added after source
  implementation; they have no separate authoritative red run. The core domain
  contract has the red evidence above. One Assistant assertion was corrected to
  use its established response fields, preserving an exact singleton resident
  and `night_float` type rather than adding an unrelated API field.
- The accepted final test SHA-256 is
  `255c5c26bc782ac6926fa6dac02bb56b8ce4844a103fd07aed2cb39f81780dd1`.
- New audit entries contain owned formatting changes. The ambiguous main-role
  entry records the branch switch away from the separate clinic-label changes;
  it is not evidence of an unauthorized source/test edit.

Dependency manifests and lockfile are unchanged. The same-session October 12
advisory evidence remains applicable: Decimal 3.1.2 fixes
GHSA-6c27-994x-c52f / CVE-2026-97853 (affected versions below 3.1.2), and the
post-upgrade OSV check found no matches among 51 locked Hex packages. The active
local OTP 29.0.1 runtime still has the 40 pre-existing advisories listed with
component versions and exposure conditions in the linked security report.
Patched release options are 29.1.1, 28.5.0.7, or 27.3.4.18. Repository pins already
specify 28.5.0.7; actual production runtime and endpoint-specific exposure remain
unverified. This review does not claim those host findings are resolved.
