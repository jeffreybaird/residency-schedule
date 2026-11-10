# PR #100 automatic merge verification

Recorded November 10, 2026. The automatic merge combines feature commit
`df22dab8a63c4caef493c0c994c99f6715594950` with `main`
`114931d3526b245ecc15cc2c08a2e6d0d5bef764`. It changes no runtime/source,
configuration, assets or lock bytes relative to the feature head. Incoming work
is two existing fixture-isolation fixes and PR #98/#99 verification records;
no conflict resolution, new tests or runtime fix was needed.

The reviewer froze the merged 241-file tracked-test manifest SHA256
`3a6bc158039a8a0ccf440e2493e4ae1d4d0cf1b43b960cb2b1ca73c5d4ec017d`.
The runner regenerated and checked that exact manifest before and after checks.
Lock SHA256 remained
`52e797eba31a48eee06a6a235a41c40b5b33e277ee7a4edfc1bed6ade8131136`.

Independent copied dependency/build directories were used. Every Mix/database
command selected `MIX_ENV=test MIX_TEST_PARTITION=pr100merge` under
`/workspace/.setup/activate.sh`. Both configuration and actual
`SELECT current_database()` confirmed `residency_schedule_testpr100merge` before
the new isolated database was migrated. No development/production database,
deployment or backfill was used.

```sh
MIX_ENV=test MIX_TEST_PARTITION=pr100merge mix test test/residency_schedule_web/live/calendar_live_test.exs test/residency_schedule/cross_schedule_coverage_test.exs test/residency_schedule/strong_night_projection_test.exs test/residency_schedule/ical_test.exs test/residency_schedule/ical_events_test.exs test/residency_schedule/shift_overrides/effective_segments_test.exs
```

Result: **16 doctests, 110 tests, zero failures**, 7.2 seconds, seed `609366`,
exit zero. This covers general calendar LiveView behavior, cross-schedule scope,
Strong night metadata, effective segments and iCalendar behavior. Read-only
formatting, warnings-as-errors compilation, strict Credo (379 files, 69 checks,
no issues), unused-lock and whitespace checks passed.

The feature's staffing-summary assertions in
`test/residency_schedule_web/live/calendar_highland_assignments_test.exs`
remain unchanged. Their earlier feature verification is historical evidence,
not part of this fresh focused selection.

A fresh Hex audit exited 1 with the same two known findings: Ecto 3.14.2 high
EEF-CVE-2026-118391 / CVE-2026-118391 / GHSA-cxjx-vmm2-qr8r (JSON-path/splice
query-cache growth; fixed in 3.14.3), and Phoenix.HTML 4.3.0 medium
EEF-CVE-2026-117645 / CVE-2026-117645 (unvalidated attribute-name injection;
fixed in 4.4.0 on the installed major). The compatible dependency fixes remain
separate in [PR #103](https://github.com/jeffreybaird/residency-schedule/pull/103);
none was suppressed or changed here.

No new whole-suite run was performed for this runtime-identical automatic merge;
the earlier feature verification remains historical evidence, not a fresh run.
No timeout or assertion changed. Native hook activation is unverified; accepted
hashes, role ownership and independent review provide the workflow evidence.
