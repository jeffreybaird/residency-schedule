# Gantt assignment details verification

Authoritative runner evidence, 2026-10-03. Runner made no source or test edits,
production writes, or deployments. The independent reviewer accepted the test
contracts before their corresponding implementation fixes.

## Red

- `MIX_ENV=test mix test test/residency_schedule_web/live/gantt_rotation_details_test.exs`
  exited 2: **9 doctests, 9 tests, 9 failures**, seed 778484. Missing clickable
  pills and scoped detail behavior caused the UI failures; existing doctests
  passed.
- `MIX_ENV=test mix test test/residency_schedule_web/live/gantt_rotation_gap_test.exs`
  exited 2: **1 test, 1 failure**. Nonadjacent intervals were incorrectly merged,
  removing the separate pill and risking inclusion of tasks from the gap.

The first full implementation run also found two existing date-update tests
whose label spans had been removed when pills became buttons. The implementer
restored nested label spans, preserving both native buttons and the accepted
tests. No assertions were weakened.

## Final green

- Exact final source: `MIX_ENV=test mix test --max-cases 1` exited 0:
  **185 doctests, 1,379 tests, 0 failures**, seed 86127, 33.2 seconds.
  Serial execution avoids the previously documented concurrent database-test
  deadlock without excluding tests.
- `MIX_ENV=test mix format --check-formatted`: exit 0.
- `MIX_ENV=test mix compile --warnings-as-errors`: exit 0.
- `MIX_ENV=test mix deps.unlock --check-unused`: exit 0; no lockfile edits.
- `MIX_ENV=test mix credo --strict`: exit 0; 248 source files,
  2,065 modules/functions, no issues.

Final accepted SHA-256 hashes remained unchanged:

```text
8399ec9c445331837d9bc479738fa636eade68a11298adf343d0e5d2ac2f6358  test/residency_schedule_web/live/gantt_rotation_details_test.exs
4f10b7f9e10c7d212495f416f70aa88d677738577439b415315c0cf4b9e5ea26  test/residency_schedule_web/live/gantt_rotation_gap_test.exs
```

The verification includes database-backed LiveView interactions, scoped server
state, modal lifecycle, and gap exclusion. The runner did not perform a separate
browser visual inspection. See [security review](qgenda-security-review.md) for
dependency and existing runtime findings; functional green is not a clean-runtime
security claim.
