# Task mappings and classifications verification

Recorded October 27, 2026. This records local isolated test-database work only.
No production deployment, migration, backfill or credentials were accessed.

## Baseline and environment

- Starting source: merged `main` commit
  `e9b1e0b784193eeccb494234539c9b367b1b3ea9` (PR #90).
- `deps` and `_build` were copied into this worktree from the resident identity
  checkout; neither is a mutable symlink to the sibling worktree.
- Runtime: `/workspace/.setup/activate.sh`, Elixir 1.19.5, Erlang/OTP 28.
- Every Mix/database command explicitly selected `MIX_ENV=test` and
  `MIX_TEST_PARTITION=classifications`. Before migration, the runner checked both
  configured database and actual `SELECT current_database()` result:
  `residency_schedule_testclassifications`.
- Existing migrations through `20261027150732` were applied only to this newly
  created isolated test database. The local development database was not used.
- Lock SHA256:
  `0ca292f932368c6241c5b8208cad03873047b992a672f6c6db3a54cc3d49390d`.
- Additional sandbox network permissions allowed local database/Mix sockets and
  the existing network proxy; no production access was requested.

The baseline test command was:

```sh
MIX_ENV=test MIX_TEST_PARTITION=classifications mix test test/residency_schedule/importer/csv_parser_test.exs test/residency_schedule/importer/qgenda_preview_test.exs test/residency_schedule/contexts/detailed_schedules_test.exs test/residency_schedule/contexts/detailed_schedule_integrity_test.exs test/residency_schedule/strong_night_projection_test.exs test/residency_schedule/hnf_post_call_projection_test.exs test/residency_schedule/schedule_gaps_index_test.exs test/residency_schedule/contexts/rotations_test.exs test/residency_schedule/assistant/assistant_test.exs test/residency_schedule/ical_test.exs test/residency_schedule/ical_overrides_test.exs test/residency_schedule_web/live/calendar_clinic_labels_test.exs test/residency_schedule_web/live/calendar_highland_assignments_test.exs test/residency_schedule_web/live/calendar_redundant_assignments_test.exs test/residency_schedule_web/live/qgenda_schedule_gaps_test.exs test/residency_schedule_web/controllers/ical_feed_test.exs
```

Result: **2 doctests, 304 tests, zero failures**, 11.9 seconds, seed `849178`, exit zero.
This covers existing CSV/QGenda behavior, schedule-gap reference comparisons,
Saturday Highland/Friday Strong projections, rotations, assistant queries,
calendar displays and iCalendar exports. Existing reference-range warnings were
retained. Complete output was redirected to
`/tmp/task-classifications-baseline-tests.log` to contain noisy profiling output.

A fresh `mix hex.audit`, under the same explicit test environment, exited zero:
“No retired or security advisory packages found.” This is a Hex package advisory
check, not a comprehensive OS/runtime/browser/vendored dependency audit.

## Implementation verification

The runner checked these exact final test hashes before the red run and again
after it; the reviewer accepted them before any source implementation:

| Path | SHA256 |
| --- | --- |
| `test/residency_schedule/contexts/task_mappings_test.exs` | `9df4db83d0f57250ae03d121ed053ad52780fd454abdee047f6c552362ec9a6b` |
| `test/residency_schedule/repo/migrations/add_task_classifications_test.exs` | `fea156d91f3f3a42b32cd97bd36a99161c1c6ca409d9862d3b0a87c07dacd6a2` |
| `test/support/task_mapping_doctest_fixtures.ex` | `be743cf7efea73d23bbaff6eb549a8844a3ab02fc243be17e74e55d1c4cdb01c` |

The first reviewer snapshot of the core test preceded the writer's already
requested final formatting. The runner's command observed the final hash above;
the reviewer then explicitly accepted that unchanged hash before implementation
was released. No test changes occurred during or after the run.

After reconfirming actual database `residency_schedule_testclassifications`:

```sh
MIX_ENV=test MIX_TEST_PARTITION=classifications mix test test/residency_schedule/contexts/task_mappings_test.exs test/residency_schedule/repo/migrations/add_task_classifications_test.exs
```

Result: **20 tests, 20 failures**, 1.8 seconds, seed `241774`, exit 2. All failures
were expected `UndefinedFunctionError` for the absent task-mapping context,
release backfill wrapper or migration SQL API. Fixtures and existing database
operations worked; unrelated setup errors were not used as red evidence.
Complete output: `/tmp/task-classifications-red.log`.

Native source/test hook activation has not been verified; role ownership and
accepted-test hashes are checked independently.

## Expanded contract and first implementation run

The reviewer accepted two safety regressions before their implementation fixes:
unsupported legacy rule versions must not classify, and an edited multi-target
set must not manufacture a unique meaning. Expanded core hash:
`a349badac82bc80b3612b9d370b84bdedd4c2774ccb82b4af09fad14b46d79fd`.
The new doctest registration hash was
`d7eff0c060db93d4d7049e305d9068f7ff515592eeda2d345a21be3c4006e64a`;
migration contract and fixture hashes remained unchanged.

After another actual-database check, migration `20261027174000` was applied to
the isolated classifications test database. The runner executed core, doctest
and migration paths together. Result: **15 doctests, 23 tests, three failures**,
2.8 seconds, seed `835347`, exit 2. Two failures demonstrated exactly the missing
safety guards above and released their source fixes. One core deletion fixture
left a detailed activity after deleting its source and batch, hitting the existing
membership foreign key before schedule deletion. That fixture correction was
returned to the test writer; no assertion was dropped by the runner.

Initial read-only formatting and warnings-as-errors compilation passed. Strict
Credo found one test alias ordering issue, returned to the test writer. The
unused-lock check and a fresh Hex audit passed; lockfile hash stayed unchanged.
The reviewer accepted the writer's lifecycle fixture correction (remove its
remaining detailed activity before deleting the schedule) and alias ordering
correction, without weakening any assertion. Final core contract SHA256:
`b27e02e5d0e1dac4975c9dd1115204b4bd71a7225ba58254c9fcba6002f0a5dc`.
Other accepted hashes above remained unchanged. The implementer added the two
reviewed classifier guards and formatted owned source files before verification.

## Final verification

The final frozen targeted command was:

```sh
MIX_ENV=test MIX_TEST_PARTITION=classifications mix test test/residency_schedule/contexts/task_mappings_test.exs test/residency_schedule/contexts/task_mappings_doctest_test.exs test/residency_schedule/repo/migrations/add_task_classifications_test.exs
```

Result: **15 doctests, 23 tests, zero failures**, 4.7 seconds, seed `146292`, exit zero. Migration
helper compile-time warnings from runtime loading remained visible; migration
behavioral assertions passed. Final read-only formatting, warnings-as-errors
compilation, strict Credo (356 files, 69 checks, no issues), unused-lock check,
fresh Hex audit and diff whitespace check all exited zero. The fresh audit
reported no retired or security advisory packages. The lockfile retained the
baseline SHA256 above.

The genuine unfiltered full suite ran on the same frozen source/tests:

```sh
MIX_ENV=test MIX_TEST_PARTITION=classifications mix test
```

Result: **268 doctests, 1817 tests, zero failures**, 88.3 seconds, seed `424243`,
exit zero. Output was redirected to `/tmp/task-classifications-full-final.log`
to contain existing profiling output and reference-range warnings; no tests were
filtered. All four accepted test/fixture hashes and `mix.lock` were checked
afterward and remained unchanged.

Final read-only checks used:

```sh
MIX_ENV=test MIX_TEST_PARTITION=classifications mix format --check-formatted
MIX_ENV=test MIX_TEST_PARTITION=classifications mix compile --warnings-as-errors
MIX_ENV=test MIX_TEST_PARTITION=classifications mix credo --strict
MIX_ENV=test MIX_TEST_PARTITION=classifications mix deps.unlock --check-unused
MIX_ENV=test MIX_TEST_PARTITION=classifications mix hex.audit
git diff --check
```

The source and test owners completed their own `mix format --force` commands
before these read-only checks. No source or test edits occurred during the final
whole-suite run.

Limits: local synthetic and isolated test-database results establish no actual
production migration, backfill or deployment. Existing readers and writers
remain authoritative. Native audit/source-edit hook activation was not verified;
role ownership, accepted test hashes and independent review provide the recorded
workflow evidence. The Hex audit does not cover OS/runtime/browser/vendored
dependencies.
