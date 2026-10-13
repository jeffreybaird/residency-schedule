# QGenda fallback for missing schedule dates

## Contract

When a resident has imported QGenda activities on a date with no stored rotation,
the displayed schedule uses those activities. This applies on every weekday,
including weekend vacation dates omitted from the original schedule. Existing
rotations and coverage assignments retain precedence; the existing Friday
Ambulatory correction continues to apply independently.

Exact task names with one reviewed rotation equivalent use that category. The
existing Saturday Highland night classification is retained. Other ambiguous or
unknown tasks appear under their literal names as QGenda assignments without
inventing a service category or working hours. Neutral assignments do not count
as working shifts or imply a shared coworker service. Known working duties count
each worked date once; Vacation and Post Call remain nonworking.

The fallback is derived in memory. Original rotations, QGenda activities, and
editor data remain unchanged. Read-only views, resident details, coworker queries,
Assistant answers, and calendar exports consume the same fallback. Synthetic
entries have no persisted rotation ID and cannot be used as stored rotations for
editing or coverage changes.

## Verification

Authoritative red command:

```sh
MIX_ENV=test mix test test/residency_schedule_web/live/qgenda_schedule_gaps_test.exs --seed 0
```

Exit 2: **7 tests, 6 failures**, 0.5 seconds.
Log: `/tmp/qgenda-gap-red.log`.
Initial formatted contract SHA-256:
`c286f016f5192fa7e37d1a711b24df38889137a7614a4d6d77d9dc8b04d6ea56`.

The refined pre-implementation contract also exited 2: 7 tests, 6 failures,
0.6 seconds, `/tmp/qgenda-gap-red-v2.log`. Reviewer accepted that contract before
implementation. The activity-only fixture and doctest registration were added
later with independent acceptance; no separate pre-implementation red is claimed
for those additions.

Initial focused green passed 9 doctests and 80 tests. Independent source review
then found three defects and the writer added focused regressions. Authoritative
red for that bundle: exit 2; **1 doctest, 9 tests, 3 failures**, 0.8 seconds,
`/tmp/qgenda-gap-review-red.log`. Failures were exactly the Assistant service
breakdown, chronological sorting, and Vacation ICS end date. The implementer fixed
those after reviewer acceptance. A source complexity offense and a test alias
style offense were corrected by their respective owners; the reviewer verified
the alias-only test correction preserved all assertions.

Final accepted SHA-256:

```text
778a421829d55338318ca08b2bdf66cda8a7933562ab3f40ebc00bb5df89d3db  test/residency_schedule_web/live/qgenda_schedule_gaps_test.exs
d0e67fb224316bd25a16422eb9e1369e5eafbd8360d8c120108ac4984a0b4b6f  test/residency_schedule/assistant/assistant_test.exs
```

### Green checks

Owners formatted their files before runner read-only verification.

```sh
MIX_ENV=test mix test test/residency_schedule_web/live/{qgenda_schedule_gaps,friday_night_float,resident_specific_rotations}_test.exs test/residency_schedule/contexts/rotations_test.exs --seed 0
```

- Focused final behavior run: exit 0; **9 doctests, 82 tests, 0 failures**,
  1.2 seconds. Log: `/tmp/qgenda-gap-focused-final.log`.
- `MIX_ENV=test mix format --check-formatted`: exit 0.
- `MIX_ENV=test mix compile --warnings-as-errors`: exit 0.
- `MIX_ENV=test mix deps.unlock --check-unused`: exit 0.
- Final `MIX_ENV=test mix credo --strict`: exit 0; 275 files, 2,246 modules/functions,
  no issues. Log: `/tmp/qgenda-gap-checks-approved.log`.
- First full suite: exit 2; 205 doctests, 1,550 tests, 6 failures, 51.5 seconds,
  seed 298741. Log: `/tmp/qgenda-gap-full-green.log`. Five compatibility failures
  were fixed in source: two minimal grid-map identity failures, two grid label
  markup expectations, and neutral task-panel wording. The sixth was an existing
  Assistant metadata assertion; the writer added the approved nonworking neutral
  category to its expected list, with reviewer acceptance and no other changes.
- Compatibility-focused run of the gap, date-upload, Gantt-detail, schedule,
  daily-assignment and Assistant test files: exit 0; **11 doctests, 114 tests,
  0 failures**, 8.3 seconds, seed 0.
  Log: `/tmp/qgenda-gap-compatibility-green.log`.
- Final format and compilation checks: exit 0.
- Final Credo after compatibility corrections: exit 0; 275 files,
  2,248 modules/functions, no issues.
  Log: `/tmp/qgenda-gap-compatibility-checks.log`.
- Final `MIX_ENV=test mix test --seed 298741`: exit 0; **205 doctests, 1,550 tests,
  0 failures**, 52.1 seconds. Log: `/tmp/qgenda-gap-full-final.log`.
  The private-data sentinel is intentional test output.
- Both accepted test hashes above remained unchanged after final execution.
- `git diff --check`: exit 0.

The runner did not edit source or tests. Runtime remains Elixir 1.19.5 on local
OTP 29.0.1; Mix requires native escalation for localhost sockets and the test
database. No JavaScript/assets changed; no unrelated asset checks repeated.

## Security

Review current changes against the existing
[October 12 advisory report](qgenda-oct12-security-review.md), including its
unresolved local runtime findings and production-runtime verification limits.

## Independent review

The reviewer inspected the shared projection, task mapping, synthetic identities,
effective segments, calendar and resident presentation, grid selection, Assistant
counts, and ICS export. Final acceptance follows the independently reviewed
corrections and runner evidence: 205 doctests and 1,550 tests pass with zero
failures; required format, compile, dependency, Credo, and diff checks pass.
The accepted hashes remain unchanged:

- Gap contract: `778a421829d55338318ca08b2bdf66cda8a7933562ab3f40ebc00bb5df89d3db`.
- Assistant contract: `d0e67fb224316bd25a16422eb9e1369e5eafbd8360d8c120108ac4984a0b4b6f`.

No implementation blockers remain.

The projection uses the complete activity roster, including residents without
stored rotations. It tests base and coverage occupancy before grouping fallback
tasks; adding one task does not suppress another on the same date. Synthetic
entries retain virtual source tasks and dates, have no database ID, and are
excluded from the editor's allowed rotation inventory. Grid identity includes
resident, category, source labels, and dates. Neutral assignments have no shared
service, coworker action, inferred work count, or invented timed event.

The review identified three bounded corrections, each demonstrated by a new
failing regression before its source correction:
retain every service in the Assistant breakdown while counting a worked date
once; sort projected dates chronologically across months and years; and preserve
an imported single-day Vacation event before a legacy night shift instead of
trimming it to zero duration. Existing legacy timing remains unchanged. Imported
night deduplication compares the actual interval and hospital, preserving a
simultaneous duty at the other site. Raw task text is escaped for ICS output.

The full suite also caught grid compatibility regressions: optional resident IDs
in public helper inputs and exact abbreviation text whitespace. Source corrections
preserve those existing tests. The neutral category label remains “Daily
assignments,” retaining the existing prohibition on provider/provenance wording
in resident details. Only the Assistant's expected non-working category list
changed to include the approved neutral category; existing numeric assertions
remain unchanged.

The activity-only fixture, editor-inventory guard, and executable happy-path
projection doctest strengthen the initial contract; their addition followed
the initial red run. Test changes belong to the writer. The final audit contains
11 new entries. One ambiguous implementer-formatting entry also observes the
Assistant expected-list edit: its command names only source files, and the
overlapping writer operation and accepted writer hash establish the test edit's
ownership. It is not an unauthorized edit finding. Other entries contain
owner-scoped formatting changes without violations.

The dependency manifest and lockfile are unchanged. Same-session October 12
advisory checks remain applicable: Decimal 3.1.2 fixes GHSA-6c27-994x-c52f /
CVE-2026-97853 (affected below 3.1.2), and the post-upgrade OSV check found no
matches among 51 locked Hex packages. The active local OTP 29.0.1 runtime still
has the 40 pre-existing advisories listed individually in the linked report,
with affected components, patched versions, and exposure conditions. Patched
release options are 29.1.1, 28.5.0.7, or 27.3.4.18. Repository pins specify
28.5.0.7; actual production runtime and endpoint-specific exposure remain
unverified. This change does not resolve those host findings.
