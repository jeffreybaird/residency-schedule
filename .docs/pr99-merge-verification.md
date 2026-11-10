# PR #99 merge verification

Recorded November 10, 2026. Local synthetic/test-database validation only; no
production service, deployment, migration, backfill or credentials were accessed.

## Merge contract

Merge validation combines branch commit
`e17e365d80dbf864df61504e279b42201183aba1` with
`main` commit `b1e19e2366d6d41eca53b8a9b1be0f9811216c10`.
The source owner resolved the single `rotations.ex` conflict by preserving the
PR #99 coverage-projection helper call, which carries foreign-schedule source
metadata. The resulting file is byte-identical to PR #99's prior version:
SHA256 `1558e1d6110d4f308f3de06d98cff7d91071be5f19ad7d245e7fcb2df25268c2`.
The source owner ran `mix format --force` on the owned source before checks.

The reviewer accepted the unchanged merged 241-file tracked-test manifest:
`094539db03961e8af5736d921a4fc444382d04a33ea61c06fc4a199ca7383ea1`.
The runner regenerated it using `git ls-files test` order with one per-file
`SHA256  relative-path` line and verified the exact result before tests.
The old lock remains unchanged at SHA256
`52e797eba31a48eee06a6a235a41c40b5b33e277ee7a4edfc1bed6ade8131136`.

## Environment and focused checks

Own `deps`/`_build` directories were copied from the PR #98 worktree, with no
mutable symlinks. Every Mix/database command explicitly used
`MIX_ENV=test MIX_TEST_PARTITION=pr99merge` under
`/workspace/.setup/activate.sh`. Configured and actual `SELECT current_database()`
both confirmed `residency_schedule_testpr99merge` before migration. Only this new
isolated database was created/migrated; the local development database was not used.

```sh
MIX_ENV=test MIX_TEST_PARTITION=pr99merge mix test test/residency_schedule/cross_schedule_coverage_test.exs test/residency_schedule/strong_night_projection_test.exs test/residency_schedule/contexts/rotations_test.exs test/residency_schedule/shift_overrides/effective_segments_test.exs test/residency_schedule/ical_test.exs test/residency_schedule/ical_overrides_test.exs test/residency_schedule/ical_events_test.exs test/residency_schedule_web/controllers/ical_feed_test.exs test/residency_schedule_web/live/calendar_highland_assignments_test.exs test/residency_schedule_web/live/calendar_redundant_assignments_test.exs
```

Result: **16 doctests, 208 tests, zero failures**, 17.3 seconds, seed `665787`,
exit zero. These cover cross-schedule coverage, Strong night source metadata,
effective rotations, calendars and iCalendar exports.

Read-only formatting, warnings-as-errors compilation, strict Credo (379 files,
69 checks, no issues), unused-lock and whitespace checks all passed.

A fresh Hex audit exited 1 with exactly two known findings:

- Ecto 3.14.2: high EEF-CVE-2026-118391 / CVE-2026-118391 /
  GHSA-cxjx-vmm2-qr8r, unbounded cache growth through interpolated JSON paths
  and splice lists; fixed in 3.14.3.
- Phoenix.HTML 4.3.0: medium EEF-CVE-2026-117645 / CVE-2026-117645,
  attribute injection through unvalidated attribute names; fixed in 4.4.0
  on the installed major.

The compatible upgrades are handled separately in
[PR #103](https://github.com/jeffreybaird/residency-schedule/pull/103). No advisory
was suppressed or dependency changed in this merge validation. Application
exposure is not established by a dependency audit alone.

The default unfiltered whole-suite run used:

```sh
MIX_ENV=test MIX_TEST_PARTITION=pr99merge mix test
```

Result: **302 doctests, 1972 tests, four failures**, 198.8 seconds, seed `56537`,
exit 2. Existing CalendarToken, iCalendarOverrides, ShiftOverrides and Residents
fixtures failed while inserting/upserting schedules after sandbox connections
exceeded their existing 15,000ms checkout limit. PostgreSQL server logs at the
matching timestamps record canceled `INSERT ... ON CONFLICT (academic_year)`
queries with `CONTEXT: while inserting index tuple (2,21) in relation schedules`.
A later scoped activity snapshot had no blocked connections; it did not identify
the earlier blocking transaction. Complete output: `/tmp/pr99merge-full.log`.

The merge task does not broaden into fixture changes. The approved unfiltered
diagnostic command retained the failed seed while serializing test modules:

```sh
MIX_ENV=test MIX_TEST_PARTITION=pr99merge mix test --seed 56537 --max-cases 1
```

Result: **302 doctests, 1972 tests, zero failures**, 198.4 seconds, seed `56537`,
exit zero. This retains internal test concurrency and all timeouts/assertions;
it does **not** establish that default parallel execution is green. Complete
output: `/tmp/pr99merge-serial-full.log`.

The accepted 241-file test manifest, resolved source hash and original lock hash
were unchanged after both full runs. No source/test/lock edits or other Mix jobs
overlapped either whole-suite run. Fresh CI under its normal parallel settings
remains the external verification step.

Native source/test hook activation was not verified. Role ownership, accepted
test hashes and independent review provide the recorded workflow evidence.
