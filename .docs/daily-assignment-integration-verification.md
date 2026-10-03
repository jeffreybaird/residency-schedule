# Daily assignment integration verification

Authoritative runner evidence, 2026-10-03. No source or test edits by the
runner; no production data writes or deployment.

## Accepted red

`MIX_ENV=test mix test test/residency_schedule_web/live/daily_assignment_integration_test.exs test/residency_schedule_web/live/qgenda_details_test.exs`
exited 2: **20 tests, 12 failures**, seed 39805. The reviewer accepted the
12 new integration tests and the intentional existing-test changes for neutral
end-user wording and removal of source-provenance presentation before source
implementation.

## Final green

- The same targeted command passed after final component-doctest wiring:
  **1 doctest, 20 tests, 0 failures**, seed 153497. The implementation was
  unchanged; the full-suite count below predates this additional wired doctest.
- Final source: `MIX_ENV=test mix test --max-cases 1` exited 0:
  **175 doctests, 1,369 tests, 0 failures**, seed 827244, 31.4 seconds.
  Serial execution avoids the previously documented concurrent test-database
  deadlock; no tests were excluded. This was a workaround, not verification of
  the normal parallel suite. See [the later isolation repair](parallel-test-isolation-verification.md).
- `MIX_ENV=test mix format --check-formatted`: exit 0.
- `MIX_ENV=test mix compile --warnings-as-errors`: exit 0.
- `MIX_ENV=test mix deps.unlock --check-unused`: exit 0, without lockfile edits.
- `MIX_ENV=test mix credo --strict`: exit 0; 246 files, 2,046 modules/functions,
  no issues.

The first full run found one existing preferred-name assertion failing because
the neutral activity panel no longer showed the resident's preferred name.
The implementer restored that heading; the accepted assertion was retained,
and the complete suite passed afterward. Final test hashes match acceptance.

```text
a8cb602e55b6d4e0039c91149da89d046afda6fd6be6c26ecefa795c620f80b1  test/residency_schedule_web/live/daily_assignment_integration_test.exs
e5196c6150e627c06042d4c91d01a0eaf408fd0b819eb82a26f3048037759b71  test/residency_schedule_web/live/qgenda_details_test.exs
```

Verification used database-backed LiveView tests. A separate browser visual
inspection was not performed by the runner. See the
[security review](qgenda-security-review.md) for dependency and pre-existing
runtime findings; functional green does not establish a clean runtime.
