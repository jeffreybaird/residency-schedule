# Resident-specific rotations verification — October 12, 2026

Authoritative workflow-runner evidence. No source/test edits by the runner.
Runtime: Elixir 1.19.5, local OTP 29.0.1. Repository-pinned OTP 28.5.0.7 was not
installed locally. Native escalation was needed for Mix sockets/test DB and the
JavaScript palette test's headless Chrome subprocess.

## Red and accepted contract

All focused Mix commands used `MIX_ENV=test mix test <paths> --seed 0`.

- Initial seven-file contract: exit 2; 5 doctests, 116 tests, 33 failures,
  5.8 seconds. Log: `/tmp/resident-specific-red.log`; original hashes:
  `/tmp/resident-specific-red-hashes.txt`.
- User-requested omission of calendar position codes: calendar rotation groups
  file exited 2; 7 tests, 2 expected failures, 0.5 seconds.
  Log: `/tmp/calendar-no-position-red.log`.
- First implementation run: exit 2; 9 doctests, 197 tests, 9 failures, 14 seconds.
  Log: `/tmp/resident-specific-focused-green.log`.
- Reviewer accepted harness corrections for the removed route's returned 404 and
  full-page navigation rendering, corrected HH expectations for matching actual
  base groups, and independent wrong-heading fixtures. The shared equivalence
  module's four doctests were registered by the writer and reviewed. Existing
  successful-path assertions were retained under the corrected contract.

Accepted final SHA-256 hashes:

```text
af3a1ccf2948e505e977000322c03222889e50c9caf7836851c396be6dd2a3d3  test/residency_schedule_web/live/resident_specific_rotations_test.exs
0ed835f9b57cd66005190f59ed37faeb3e4bee6a8726cd4bdd68ad9f31268523  test/residency_schedule_web/live/activities_page_removal_test.exs
25db833e0f5dbd9749c590b7bbd2c42f4afb6b87025b325830fa419543127bb1  test/residency_schedule_web/live/resident_imported_schedule_test.exs
964373644dd5495ae184f2304098526db38eba384024f8eb0402d78bc5070e8c  test/residency_schedule_web/live/calendar_redundant_assignments_test.exs
8ff02c1e9bf19862846c47344fd146aaedc822255e87b937e4197a43d1bc3c93  test/residency_schedule_web/live/calendar_highland_assignments_test.exs
53e6d680c2463d532c2c315415d5c309d7eccbf3263013f42baaedc83ab80be1  test/residency_schedule_web/live/daily_assignment_integration_test.exs
783c9934a74356e8df850edb6095130c96a9c2fdde0222d7d3e007988a73bff5  test/residency_schedule_web/live/imported_resident_names_test.exs
165a78825c77ada5f401e9d0801ece85d34bcf8e1d7d8716ebe8608e47289909  test/residency_schedule_web/live/calendar_rotation_groups_test.exs
```

## Green checks

Source/test owners formatted their files before these read-only checks.

Focused command:

```sh
MIX_ENV=test mix test test/residency_schedule_web/live/{resident_specific_rotations,activities_page_removal,resident_imported_schedule,calendar_redundant_assignments,calendar_highland_assignments,daily_assignment_integration,imported_resident_names,calendar_rotation_groups,resident_live,calendar_live}_test.exs --seed 0
```

- Focused final: exit 0; **9 doctests, 197 tests, 0 failures**, 17.4 seconds.
  Log: `/tmp/resident-specific-focused-final.log`.
- `MIX_ENV=test mix format --check-formatted`: exit 0.
- `MIX_ENV=test mix compile --warnings-as-errors`: exit 0.
- `MIX_ENV=test mix deps.unlock --check-unused`: exit 0.
- `MIX_ENV=test mix credo --strict`: exit 0; 270 files, 2,197 modules/functions,
  no issues. Log: `/tmp/resident-specific-checks.log`.
- `MIX_ENV=test mix assets.build`: exit 0; Tailwind and esbuild completed.
  Log: `/tmp/resident-specific-assets.log`.
- `node --test test/assets/*.test.js`: initial sandbox run had 19 passes and one
  Chrome-launch failure. Native escalated rerun passed **20 tests, 0 failures**.
  Log: `/tmp/resident-specific-js-final.log`.
- `MIX_ENV=test mix test --seed 298741`: exit 0; **200 doctests, 1,523 tests,
  0 failures**, 40.1 seconds. Log: `/tmp/resident-specific-full-green.log`.
  The private-data sentinel is intentional test output.
- All accepted hashes above remained unchanged after final execution.
- `git diff --check`: exit 0.

## Security scope

The same-session [security review](qgenda-oct12-security-review.md) remains
applicable: dependency versions unchanged, known local OTP advisories unresolved.
Tests do not verify production runtime or establish a clean local runtime. No
production writes were performed by the runner.
