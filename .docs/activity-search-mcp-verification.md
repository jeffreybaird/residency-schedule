# MCP activity search verification

Authoritative runner evidence, 2026-10-03. No source or test edits by the runner;
no production writes, imports, or deployment.

## Red evidence and workflow correction

The initial pre-implementation command ran both new test files and exited 2
with 10 tests and 9 failures. Those failures were **invalid fixture setup**:
a helper derived an invalid email address containing spaces from a full name.
The runner initially mischaracterized them as missing-tool failures. They did
not establish a meaningful red gate, and implementation had already begun when
the mistake was discovered. This is a workflow deviation, not a normal
red-before-implementation sequence.

The spec writer corrected the caller fixture with reviewer acceptance. To
recover valid baseline evidence without changing the current implementation,
the runner archived pre-MCP commit `fc0fe64` to `/tmp/residency-mcp-red-base`;
the spec writer copied the corrected owned tests into that archive. It used a
separate build directory and test database (`MIX_TEST_PARTITION=_mcp_red_base`).

In that archive:

`MIX_ENV=test MIX_TEST_PARTITION=_mcp_red_base mix test test/residency_schedule_web/mcp/activity_search_test.exs test/residency_schedule_web/controllers/mcp_activity_search_auth_test.exs`

exited 2: **10 tests, 8 failures**. Fixtures succeeded. Failures specifically
showed `{:error, :unknown_tool}`, missing catalogue/guidance definitions, and
protocol rejection of `search_activities`. Existing compatibility and auth
checks passed. This is **retrospectively recovered red evidence**, not evidence
that the corrected tests ran before implementation.

The recovered-red MCP test hash was
`bf23212db127a08d7b6ecbe2cfa3b99fadaf646b180fc696b461796853d50075`.
Only alias ordering changed afterward for Credo, with renewed reviewer acceptance.
Behavioral assertions were retained.

## Final green

- Corrected targeted contract: **10 tests, 0 failures**, exit 0.
- Exact final implementation: `MIX_ENV=test mix test`, normal parallelism
  (`max_cases: 16`), exited 0: **187 doctests, 1,405 tests, 0 failures**,
  seed 569932, 29.4 seconds.
- `MIX_ENV=test mix format --check-formatted`: exit 0.
- `MIX_ENV=test mix compile --warnings-as-errors`: exit 0.
- `MIX_ENV=test mix deps.unlock --check-unused`: exit 0, lockfile unchanged.
- `MIX_ENV=test mix credo --strict`: exit 0; 258 files,
  2,123 modules/functions, no issues.

Final contract SHA-256 hashes:

```text
e8eca4103092f93c95a52b5c4f086f18dc773782754a3b736f617571e45a465c  test/residency_schedule_web/mcp/activity_search_test.exs
fc9f7aab35b8684a5920819d746cee6a98627e767c599b03b36897853696836f  test/residency_schedule_web/controllers/mcp_activity_search_auth_test.exs
```

Verification exercises tool discovery, shared context results, literal note and
name searches, bounded pagination, malformed inputs, protocol/chat dispatch,
existing rotation result shapes, and access control. See
[security review](qgenda-security-review.md) for dependency and runtime findings;
functional green is not a clean-runtime security claim.
