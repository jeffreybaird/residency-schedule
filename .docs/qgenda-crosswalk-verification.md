# Optional QGenda crosswalk upload verification

Authoritative runner evidence, 2026-10-02. No source or test edits were made
by the runner. Commands used local Elixir 1.19.5 / Erlang OTP 29 with sandbox
escalation for Mix's local TCP socket and database connections.

## Red and accepted contract

`MIX_ENV=test mix test test/residency_schedule/importer/qgenda_uploaded_crosswalk_test.exs`
exited 2 before implementation: **14 tests, 13 failures**, seed 419843.
The failures demonstrated absent uploaded-crosswalk processing and UI support.
The reviewer accepted the test contract before implementation.

`MIX_ENV=test mix test test/residency_schedule/importer/qgenda_crosswalk_rejection_test.exs`
initially exited 2: **5 tests, 4 failures**. This included genuine stale-mapping
and unfinished-upload failures as well as an upload test-harness mismatch.
The test writer corrected assertions about the LiveView upload return shape
and supplied realistic MIME metadata for the unsupported file fixture; the
reviewer accepted those corrections. Required visible rejection and absence
of a fallback preview remained unchanged. The final corrected fixture was
verified green after the source fixes; no retrospective red run is claimed
for the final harness bytes.

## Final verification

- `MIX_ENV=test mix test`: exit 0; **174 doctests, 1,311 tests, 0 failures**,
  seed 745310, 26.1 seconds.
- `MIX_ENV=test mix format --check-formatted`: exit 0.
- `MIX_ENV=test mix compile --warnings-as-errors`: exit 0.
- `MIX_ENV=test mix deps.unlock --check-unused`: exit 0; no lockfile mutation.
- `MIX_ENV=test mix credo --strict`: exit 0; 228 source files,
  1,965 modules/functions, no issues.

Final accepted SHA-256 hashes:

```text
7ea8ec4a494ab49e2076e2b643d08f5a88eb9087053cd1f385ec8b7e58b05f95  test/residency_schedule/importer/qgenda_uploaded_crosswalk_test.exs
113abd799269609e1ce7538a551750d85b51dfda087730bdf5ab7a780108c855  test/residency_schedule/importer/qgenda_crosswalk_rejection_test.exs
```

## Actual uploaded CSV path

Read-only comparison established that the local selected-year roster and the
production roster snapshot have identical names and positions: **32 rows each**.
Then `mix run -e ...` invoked the public `QgendaPreview.prepare/2` API with
the actual XLSX and `crosswalk_csv:` read from the ignored crosswalk artifact.
This exercised uploaded CSV validation and reconciliation, not the older
explicit-alias option. Database access was read-only; no real-data inserts,
updates, or deletions occurred. Only aggregate results were printed.

| Check | Result |
| --- | ---: |
| Total assignments | 8,645 |
| Matched assignments | 7,779 |
| Matched residents | 31 |
| Missing roster position | R4-1 |
| Linked resident notes | 206 |
| Crosswalk warnings | 0 |

The command asserted all assignment, resident, missing-position, and note
counts and exited 0. This is local read-only verification against a roster
equal to the production snapshot, not a production upload or deployment test.

## Security scope

The independent reviewer refreshed checks for all 47 locked Hex dependencies:
no matching advisories or retired packages were reported. Existing runtime
advisories remain documented in [the security review](qgenda-security-review.md).
Passing dependency checks does not establish a clean runtime or deployment.
