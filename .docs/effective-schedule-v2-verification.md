# Evidence-driven v2 verification

Baseline `18580093b99d41b206acdba16347e710e138241e`, after the isolated
legacy fixes and Friday policy enrichment in PRs #97–101. This delivery implements
the second item of the [Phase 3 plan](schedule-effective-read-plan.md), with the
[evidence contract refinements](effective-schedule-v2-contract.md). Consumers
remain on legacy reads. No production comparison, migration, backfill or deployment
is implied by local verification.

The spec writer produced 18 evidence tests and 12 policy tests, migrated the
adapter-only equality assumptions into explicit v2 expectations while preserving
legacy assertions, and added diagnostics ordering, normalization ordering and
aggregate-only release/telemetry coverage. Drafts were preserved during the
metadata prerequisite with a scoped Git stash and restored byte-for-byte against
four recorded SHA256 hashes before further edits.

## Accepted tests and red

Reviewer accepted all ten files after runner red: 10 doctests, 140 tests,
63 expected failures, seed 728030. Command: `mix test
test/residency_schedule/effective_schedule test/residency_schedule/release_compare_test.exs
test/residency_schedule/observability_test.exs test/residency_schedule_web/operation_tracing_test.exs`.
Failures exposed missing evidence APIs, semantics, precision, diagnostics, privacy
counts and total ordering. No fixture constraint failures occurred. The missing-source
case demonstrated legacy presentation failure rather than setup failure.

| Path | SHA256 |
| --- | --- |
| `test/residency_schedule/effective_schedule/acceptance_test.exs` | `de58f737873b07ca9131e66d52e16d2fd5557985cae936e264b535a94c74a891` |
| `test/residency_schedule/effective_schedule/comparison_test.exs` | `0b1ee58f245ab784055e9a50c708fe43762def8a75cd407b31258f9ef50d9dde` |
| `test/residency_schedule/effective_schedule/effective_schedule_test.exs` | `fcf39d9bc977f8df878b14e81725b9cff1e9d03e69031bdd2638c357388f08ec` |
| `test/residency_schedule/effective_schedule/normalize_test.exs` | `5c5c5c2315f5eec7763bdc2f32e500ab6fe8dafbe568f3d4d173647148740df1` |
| `test/residency_schedule/effective_schedule/v2_evidence_test.exs` | `a6db1040d6dcee1303bde0552ed104885fb2a450c127bb8d8fe4627219f7e8cb` |
| `test/residency_schedule/effective_schedule/v2_policies_test.exs` | `ab8b3d701f3d0053beba65d8ed21b4c6f04a48cfa51480156abb7572271afb36` |
| `test/support/effective_schedule_v2_fixtures.ex` | `85033f3232de3e900f506532c8e258f6a3c1a5fa119b89cff808d8807ca2d863` |
| `test/residency_schedule/release_compare_test.exs` | `f7de1e96998bf368ce500d1ad24625fd36ba2c810c3a50081e06d190359a1e22` |
| `test/residency_schedule/observability_test.exs` | `92604c69bd5db92f83c795b59adeff486ac90dd383ffd704ba4dd72ca4a04f88` |
| `test/residency_schedule_web/operation_tracing_test.exs` | `4ef9e220a93664385e17815674e11a0ddb48ebbcf21fa9af5abce60e1baa1ac3` |

## Initial performance diagnostic

The synthetic workload retains the existing schedule-cache shape: four schedules,
128 memberships, 9024 rotations and 11680 dated activities. Source aliases are
unique per synthetic membership, with 11680 retained classifications/timings and
identity observations plus 32 approvals, so the run exercises accepted evidence
rather than excluding every ambiguous source. The activity is the existing
unknown Synthetic Clinic case; this is not a period-heavy benchmark.

Initial D7 run failed the unchanged two-times limit. Seven alternating warm-run
medians: legacy raw projection 210.097 ms, legacy full daily service 295.214 ms,
v2 3902.482 ms (18.575x raw projection; 13.219x full service). First-call timings
were 273.664, 300.353 and 4122.139 ms respectively; no OS/cache eviction is claimed.
This is diagnostic failure evidence, not acceptance. The runner's EXIT trap
removed the disposable local database and verified no matching database remained.

After identity-result caching, selective loading, resident-scoped night neighbors
and comparison computation reuse, the same diagnostic workload improved to warm
medians of 266.575 ms raw projection, 376.118 ms full legacy service and 694.307 ms
v2. The service ratio passed (1.8460x), but the literal D7 projection ratio still
failed (2.6045x). This run overlapped an early focused test run; it is recorded as
diagnostic evidence and does not replace the required isolated final run. The
benchmark database was again removed and cleanup verified.

The final isolated run passed D7 after selecting only consumed classification
JSON fields and deduplicating identical retained identity observations in the
query. The unchanged workload and benchmark produced seven warm-run medians of
278.747 ms raw legacy projection, 446.399 ms full legacy service and 341.573 ms
v2: 1.225387x the literal projection baseline and 0.765174x the full service.
Both are below the unchanged 2x limit. First-call timings were 345.170, 367.868
and 427.619 ms; no cold-cache eviction is claimed. No tests or static checks ran
concurrently. The disposable database was removed and cleanup verified.

## Review-driven regression additions

Independent review added closed policy/version validation, preserved period/exact
activities even when a base rotation has the same code, registered eight pure
module doctests, and made privacy assertions distinguish private evidence detail
from the permitted `unresolved_evidence` count. The same-code precision regression
failed before its correction (12 doctests, 36 tests, one failure, seed 296465).
A corrected existing timed-event UID literal preserved that test's semantics.

Comparison caching also needed a shared person set: a held-only current schedule
must not erase that person's valid prior-year calendar events from the comparison.
The added regression failed with two differing events instead of the one current
excluded duty (one doctest, 22 tests, one failure, seed 251410). Reviewer accepted
this additional contract before its source correction.

## Independent audit review

Fresh `mix hex.audit` reported no retired or advisory packages. This is Hex-package
advisory coverage; no production exposure or operating-system scan is claimed.
The review inspected 22 new Bash audit entries, including ten flagged ambiguous
observations. They reflect permitted scoped Git restoration overlapping a push,
owned formatting calls overlapping each other, and read-only tests/benchmark/Credo
commands observing concurrent owned edits. Commands and reviewed diffs establish
no unowned authored source/test change. Logs are retained; final stable-state
checks and accepted hashes verify the resulting contract.

## Final stable-state verification

After the review-driven corrections, the focused command passed 21 doctests and
144 tests (seed 796390). The complete suite passed 314 doctests and 2021 tests,
zero failures (seed 794374, 99.7 seconds). Source and test owners ran their scoped
`mix format --force` corrections before these checks. Read-only format validation,
warnings-as-errors compilation, unused lock checks and strict Credo all passed;
Credo checked 394 files and 3163 modules/functions with no issues.

The original accepted hash table remains the red-stage record. Final reviewed
changes and additions are recorded below; all other listed files remain unchanged.

| Path | Final SHA256 |
| --- | --- |
| `test/residency_schedule/effective_schedule/acceptance_test.exs` | `c00e169deccb49c6f1aa988548b22d088fbb857197f5c9fbddd9a0eb00f22450` |
| `test/residency_schedule/effective_schedule/v2_evidence_test.exs` | `fc4411124cb3bd4c9897ae49b14fc4a78affcf72f96a422d73907c459a5f96c1` |
| `test/residency_schedule/release_compare_test.exs` | `dfabe5d9489ff627d53c387e67c92aa561f7a44660b1ae6a1e728f3b514d9155` |
| `test/residency_schedule/effective_schedule/v2_doctest_test.exs` | `7b2475d4d5241ccd9127c315c51c40546126d0827db6bc0b2fda7759bb7b9817` |
| `test/support/benchmarks/effective_schedule_v2.exs` | `57c55c9a42705b25ba0fdf705e1d78c3d725950add7c90d5a50f74d9a530f3a0` |

## Remaining acceptance gates

The user explicitly approved the first two differences on October 29, 2026,
as recorded in `schedule-effective-read-approved-differences.md`:

- A simultaneous clinic now appears as a distinct dated duty with its retained
  period beside the base rotation. Its new activity event is compared separately.
- Exact retained occurrence instants are honored instead of legacy date-derived
  calendar timing. Existing base/coverage UIDs remain stable.
- Missing classifications/timings/identity remain visible in diagnostics; v2 does
  not reconstruct their meaning from labels. Such schedules are not comparison-ready.
- Historical generic Friday evidence requires explicit append-only enrichment;
  current v2 policy works only with the enriched retained discriminator.
- Literal OFF has no stored semantic off target and remains unresolved.

Other unresolved observations remain blockers rather than silently approved differences. No
production schedule has been compared. Consumer-output comparison and unused
read controls remain the separate third and fourth deliveries of Phase 3.

## Delivery authorization

After two 1Password SSH signing failures, the user explicitly authorized one
unsigned commit on October 29, 2026. This commit uses a command-scoped signing
override; repository and global signing preferences remain unchanged. Only the
approval records changed after the final code/test review and verification.
