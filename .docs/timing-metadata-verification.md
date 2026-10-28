# Timing metadata verification

Recorded October 27–28, 2026. This records local isolated test-database work only.
No production deployment, migration, backfill or credentials were accessed.

## Deployment state inspected before this work

The GitHub deployment workflow succeeded for PR #88 (run 39663863198, commit
`907426a`). The runs for PR #89 (40525071214), PR #90 (40560080693) and
PR #91 (40565166507) each failed in the `Rehearse (staging)` job with
`Release migration or demo seeding failed; current release unchanged`, within
seconds of starting the promotion script. The release's own output is discarded
by `deploy/runtime_config.rb` (`out: File::NULL, err: File::NULL`), so the
cause is not visible from the workflow logs. PR #89 changed only `mix.lock`
(Bandit 1.14.0, plug_crypto 2.2.1) and the toolchain pins have been
Elixir 1.19.5/OTP 28 since PR #51.

Consequences: the installed release is still PR #88. The identity-mapping and
task-classification schemas are not deployed, so
`Release.backfill_identity_mappings/0` and
`Release.backfill_task_classifications/0` cannot have run, and this repository
holds no evidence that `Release.backfill_source_provenance/0` was run after
PR #88. None of the three backfills was executed from this session. Running
them requires first diagnosing the staging rehearsal failure on the server
(for example by running the failing `bin/residency_schedule eval
'ResidencySchedule.Release.migrate()'` with its output visible under the
managed runtime configuration), then a successful deployment.

## Baseline and environment

- Starting source: merged `main` commit
  `cb2a16fe165040be4908d4dcc4c6800135575d9c` (PR #91), branch
  `claude/zen-sagan-064vo0`.
- The cloud bootstrap pinned Elixir 1.18.4, which `mix.exs` rejects. The
  repository's documented official installer supplied Elixir 1.19.5 and
  Erlang/OTP 28.5.0.7 (`.tool-versions`), used for every command below.
- Every Mix/database command explicitly selected `MIX_ENV=test` and
  `MIX_TEST_PARTITION=timing`. The runner checked the actual
  `SELECT current_database()` result: `residency_schedule_testtiming`.
  Migrations through `20261027174000` were applied only to this newly
  created isolated test database.
- Lock SHA256:
  `0ca292f932368c6241c5b8208cad03873047b992a672f6c6db3a54cc3d49390d`.

The baseline test command was:

```sh
MIX_ENV=test MIX_TEST_PARTITION=timing mix test test/residency_schedule/importer/csv_parser_test.exs test/residency_schedule/importer/qgenda_preview_test.exs test/residency_schedule/contexts/detailed_schedules_test.exs test/residency_schedule/contexts/detailed_schedule_integrity_test.exs test/residency_schedule/strong_night_projection_test.exs test/residency_schedule/hnf_post_call_projection_test.exs test/residency_schedule/schedule_gaps_index_test.exs test/residency_schedule/contexts/rotations_test.exs test/residency_schedule/assistant/assistant_test.exs test/residency_schedule/ical_test.exs test/residency_schedule/ical_overrides_test.exs test/residency_schedule_web/live/calendar_clinic_labels_test.exs test/residency_schedule_web/live/calendar_highland_assignments_test.exs test/residency_schedule_web/live/calendar_redundant_assignments_test.exs test/residency_schedule_web/live/qgenda_schedule_gaps_test.exs test/residency_schedule_web/controllers/ical_feed_test.exs
```

Result: **2 doctests, 304 tests, zero failures**, 13.6 seconds, seed `852168`,
exit zero. Existing negative-range warnings from the schedule-gap reference
fixture were retained. A fresh `mix hex.audit` exited zero: “No retired or
security advisory packages found.” This is a Hex package advisory check only.

## Accepted contract and red run

The reviewer accepted these test files before any source implementation; the
runner recorded the same hashes before and after the red run:

| Path | SHA256 |
| --- | --- |
| `test/support/timing_doctest_fixtures.ex` | `1fc002e16ff7db43106286d6c498e849664c96b03a161837d7d8a3b605f13413` |
| `test/residency_schedule/contexts/timings_test.exs` | `fd02bd81d1cf58c6a82425bbf07118d819ce66f0a6685c9c7ab2c978154124d6` |
| `test/residency_schedule/contexts/timings_doctest_test.exs` | `e9695f9727f7985037fb54eb14c0ade2c6499e6566d9062c8aee0824295573dd` |
| `test/residency_schedule/repo/migrations/add_activity_source_timings_test.exs` | `8491b4cf0328bfa2a01f138d3ddf3960e8d049e538cc0532293bfdcf32aac641` |

```sh
MIX_ENV=test MIX_TEST_PARTITION=timing mix test test/residency_schedule/contexts/timings_test.exs test/residency_schedule/repo/migrations/add_activity_source_timings_test.exs
```

Result: **35 tests, 35 failures**, 3.0 seconds, seed `736361`, exit 2. Thirty-four
failures were `UndefinedFunctionError` for the absent `ResidencySchedule.Timings`
modules, migration module or `Release.backfill_timings/0`; one asserted the
absent migration file `20261028120000_add_activity_source_timings.exs`. The
doctest registration file could not compile until the modules existed, as
expected. The reviewer noted the pinned migration file name as the one
over-specification; the orchestrator chose to keep it.

Native source/test hook activation has not been verified; role ownership and
accepted-test hashes are checked independently.

## Test corrections and renewed acceptance

The implementer reported one order dependency (only the first migration test
loaded the migration file) and three strict Credo findings in the accepted
tests. The spec writer corrected them: module-level `Code.require_file`, a
tuple-argument `insert_timing!` helper, an `~s` sigil for the INSERT literal,
and alias ordering. The reviewer confirmed by comparison with the accepted
versions that no assertion, expected value or coverage changed, and accepted
the corrected hashes before the green run was recorded:

| Path | SHA256 |
| --- | --- |
| `test/residency_schedule/contexts/timings_test.exs` | `65c4c5d57d3dd19cd30150dbf5f602d3da07fd6f03d4fec0a5933f4ad6cc413c` |
| `test/residency_schedule/repo/migrations/add_activity_source_timings_test.exs` | `b8ac2f5a34cf7c37ab3e20581c4348f55638267de447b47148ffd5aa88d5bd0e` |

The fixture and doctest registration hashes were unchanged.

## Green and final verification

After confirming the actual database `residency_schedule_testtiming` and that
migration `20261028120000` was applied there, the runner executed:

```sh
MIX_ENV=test MIX_TEST_PARTITION=timing mix test test/residency_schedule/contexts/timings_test.exs test/residency_schedule/contexts/timings_doctest_test.exs test/residency_schedule/repo/migrations/add_activity_source_timings_test.exs
```

Result: **7 doctests, 36 tests, zero failures**, 1.3 seconds, seed `323899`, exit
zero; repeated with seeds `1` and `2` with the same result, confirming the
order-independence correction.

The genuine unfiltered full suite on the same frozen source and tests:

```sh
MIX_ENV=test MIX_TEST_PARTITION=timing mix test
```

Result: **277 doctests, 1853 tests, zero failures**, 106.4 seconds, seed `6948`,
exit zero. In a separate full run by the reviewer, one pre-existing,
order-dependent failure appeared once in `ResidencyScheduleWeb.AdminLive.Index`
(`handle_info/2` received an unexpected message under async scheduling) and
passed on rerun; the timing code adds no messaging or LiveView changes. This is
a lead for a separate task, not a finding against this increment.

Final read-only checks, each exiting zero:

```sh
MIX_ENV=test MIX_TEST_PARTITION=timing mix format --check-formatted
MIX_ENV=test MIX_TEST_PARTITION=timing mix compile --warnings-as-errors
MIX_ENV=test MIX_TEST_PARTITION=timing mix credo --strict
MIX_ENV=test MIX_TEST_PARTITION=timing mix deps.unlock --check-unused
MIX_ENV=test MIX_TEST_PARTITION=timing mix hex.audit
git diff --check
```

Credo reported 2930 modules/functions with no issues. The fresh Hex audit
reported no retired or security advisory packages; it covers Hex dependencies
only, not OS, runtime, browser or npm packages. The lockfile retained the
baseline SHA256. All four accepted test hashes were rechecked after every run
and remained unchanged. The source and test owners ran their own formatting
before these read-only checks.

The reviewer independently accepted the implementation: contract conformance,
no hour inference, literal source dates, no change outside the new timing
modules, the migration and `Release.backfill_timings/0`, batch locking and
rollback behaviour, and synthetic-only fixtures and documentation.

Limits: local synthetic and isolated test-database results establish no actual
production migration, backfill or deployment. The deployment pipeline is
currently failing at the staging rehearsal, as recorded above, so this
increment cannot reach production until that is resolved. Existing readers and
writers remain authoritative. Native audit/source-edit hook activation was not
verified; role ownership, accepted test hashes and independent review provide
the recorded workflow evidence.
