# Schedule source/provenance verification

Recorded October 21, 2026. Local synthetic validation only; no production service,
database or configuration was accessed.

## Runtime and existing-behavior baseline

- Starting source: merged `main` commit `3889cf4` (PR #87).
- Runtime selected with `source /workspace/.setup/activate.sh`: Elixir 1.19.5,
  Erlang/OTP 28.5.0.7 and the existing local PostgreSQL 17.11 cluster. The cluster
  was already accepting local connections; no service restart was required.
- Mix and local PostgreSQL commands used sandboxed additional network permission
  for local sockets and the ordinary configured proxy. No credentials or
  production destinations were inspected.
- Fresh `mix hex.audit` exited zero: “No retired or security advisory packages
  found.” This is a Hex package advisory check, not a comprehensive OS, Ruby,
  browser or vendored dependency audit.

The runner executed the explicit existing test paths below before new contract
tests or implementation were introduced:

```text
mix test test/residency_schedule/contexts/detailed_schedules_test.exs test/residency_schedule/contexts/detailed_schedule_integrity_test.exs test/residency_schedule/contexts/detailed_schedule_empty_import_test.exs test/residency_schedule/importer/integration_test.exs test/residency_schedule/importer/date_update_test.exs test/residency_schedule/schedule_builder test/residency_schedule/schedule_editor_test.exs
```

Result: **209 tests, zero failures**, exit zero, 5.6 seconds, seed `226929`.

## Accepted contract and authoritative red

The reviewer accepted the contract before implementation. The runner confirmed
these exact SHA256 values:

| Path | SHA256 |
| --- | --- |
| `test/residency_schedule/source_provenance_test.exs` | `91aa6d8186a8ded06fc05fb33ab0a7bd1874c34ee7386d7f4ee5502936f0523a` |
| `test/residency_schedule/repo/migrations/add_source_provenance_test.exs` | `6c1b92651154cef325342355960c3ffa958ae8469b60ce61c80e04ad0b9cfa19` |

```text
mix test test/residency_schedule/source_provenance_test.exs test/residency_schedule/repo/migrations/add_source_provenance_test.exs
```

Result before source implementation: **11 tests, 10 failures**, exit 2,
0.7 seconds, seed `421248`. Failures concern the missing provenance columns and
schema fields, backfill API, source-aware persist entry point, compiled-release
helper and migration SQL helper. The existing unknown-attribute rejection test
already passes, independently of the missing new metadata. Test fixture setup
and database access succeeded; no unrelated fixture/runtime failure was used as
evidence of red behavior.

The migration contract exercises the migration's exact additive SQL in an
isolated schema populated with legacy-shaped records. It also checks omitted-field
inserts from old writers, note/reference preservation, repeated backfill and
removal of only the added fields on migration reversal.

## Initial implementation green

After owned source formatting and warnings-as-errors compilation, both frozen
contract hashes remained unchanged. The exact two-file contract command passed:
**11 tests, zero failures**, exit zero, 0.8 seconds, seed `818202`. This includes
the populated legacy-schema SQL migration and repeated-backfill contract.

The explicit existing-behavior baseline command then passed again: **209 tests,
zero failures**, 6.2 seconds, seed `242798`. Read-only formatting, unused-lock,
fresh Hex advisory audit and diff whitespace checks passed.

Strict Credo found three new test-owned style issues: alias ordering, a fully
qualified nested module reference and a quoted SQL literal better expressed as a
sigil. The test writer corrected those mechanically and obtained renewed review.
The reviewer also accepted supplemental invalid-option and retryable-database-
failure coverage. An initial supplemental fixture attempted a raw PostgreSQL
savepoint that did not survive the SQL sandbox's per-query handling; its cleanup
failed with a missing-savepoint error. The writer repaired the fixture to use
ordinary schema cleanup without weakening the error assertion. No application
failure was established by that fixture error.

## Final accepted contract and verification

The reviewer accepted the final contract before the runner's final checks:

| Path | Final SHA256 |
| --- | --- |
| `test/residency_schedule/source_provenance_test.exs` | `be63af950764cce921d852dfd2013d33b1c1a9f308ca7bd32525b506d1edb8cc` |
| `test/residency_schedule/repo/migrations/add_source_provenance_test.exs` | `f7d6eb2d61b94bbf8f446b8856ea1c877bb3f3ecff7a97de6dbe841575e2cab3` |

The runner repeated the exact two-file contract command: **12 tests, zero
failures**, exit zero, 0.7 seconds, seed `211339`. The entire application suite
then passed on the final source and tests:

```text
mix test
```

Result: **220 doctests, 1,769 tests, zero failures**, exit zero, 76.9 seconds,
seed `728946`. Existing date-range reference warnings, profiler tables and the
synthetic privacy sentinel appeared; they did not cause test failures.

Final checks passed:

- `mix compile --warnings-as-errors`.
- `mix format --check-formatted` after source/test owners completed formatting.
- `mix credo --strict`: 332 files, no findings.
- `mix deps.unlock --check-unused`: no unused lock entries.
- Fresh `mix hex.audit`: no retired or security advisory Hex packages found.
- `git diff --check`.
- Both final accepted test hashes remained unchanged after all checks.

The native Bash audit log remains at 351 entries, including 155 historical
violation-flag entries, with the most recent timestamp October 20. It gained no
task-specific events, so native audit-hook activation is unverified. Direct
source/test role ownership and final accepted hashes were independently checked;
an installed hook is not treated as proof that it ran.

This delivery adds schema and explicit backfill tooling; only local synthetic
test migrations/backfills were executed. No production migration, backfill,
deployment, storage provisioning or recovery activation was performed.

## Independent acceptance

The independent reviewer accepted the original contract before implementation
and checked the final source, migration, source-provenance instructions and model
plan against the final accepted test hashes above. The supplemental option-shape,
compiled-release result and retryable-error cases retain the original assertions;
mechanical test style and sandbox-fixture corrections do not weaken the contract.

The migration's `up/0` and `down/0` execute the exact SQL exercised against the
populated legacy-shaped schema. New defaults preserve old omitted-field writes.
The bounded keyset backfill rechecks both the empty source reference and QGenda
source kind at update time and changes no original timestamp or identity.
Known writers record their current origin, date-update fragments preserve prior
metadata, and unchanged editor saves do not rewrite provenance. Assignment form
attributes cannot forge the trusted fields. Existing QGenda fingerprints,
coordinate identity and preview-only JSON boundaries remain intact.

The reviewer independently repeated the fresh Hex advisory audit: exit zero,
no retired or security advisory Hex packages. The dependency lock remains
`bb51b87fb5488f325608ea2c5ea3c773f384c67765de9dc317455fb863b03697`.
This does not establish comprehensive OS, runtime or vendored-package coverage.
Native audit activation remains unverified as described above; direct role
ownership and final hashes corroborate the edits.

No actionable source, test or documentation finding remains after the runner's
final full-suite and static-check results. This acceptance covers the local
schema/backfill delivery; it does not claim production execution.
