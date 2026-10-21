# Schedule adapter boundary verification

Recorded October 21, 2026. This record covers local synthetic validation only;
no production service, database or configuration was accessed.

## Runtime and baseline

- Runtime selected with `source /workspace/.setup/activate.sh`: Elixir 1.19.5,
  Erlang/OTP 28.5.0.7 and local PostgreSQL 17.11.
- The existing local PostgreSQL cluster was stopped. It was started using its
  existing data directory and loopback/socket configuration. The ordinary sandbox
  denied local TCP sockets for PostgreSQL and Mix PubSub; sandboxed additional
  network permission allowed both without changing project configuration.
- `mix deps.get` synchronized previously fetched Bandit and Thousand Island to
  locked versions 1.13.0 and 1.6.0. The lock file remained byte-identical:
  SHA256 `bb51b87fb5488f325608ea2c5ea3c773f384c67765de9dc317455fb863b03697`.
- Existing baseline command:
  `mix test test/residency_schedule/importer/csv_parser_test.exs test/residency_schedule/importer/integration_test.exs test/residency_schedule/importer/date_update_test.exs test/residency_schedule/importer/qgenda_preview_test.exs test/residency_schedule/schedule_builder`.
  Result: **215 tests, zero failures**.
- Fresh `mix hex.audit` after dependency synchronization exited zero with
  “No retired or security advisory packages found.” This checks current Hex
  package advisories; it is not a comprehensive OS, Ruby, browser or vendored
  dependency audit.

## Preliminary red observation

An initial directory-based importer/builder baseline run picked up the test
writer's new `adapter_boundary_test.exs` during compilation. It reported
14 doctests and 325 tests, with eight failures caused by missing adapter modules.
The explicit existing baseline above avoids treating that mixed run as a clean
baseline. The accepted-contract red run and hashes will be recorded separately.

## Accepted-contract red run

The test writer formatted the final contract before the runner executed:

```text
mix test test/residency_schedule/importer/adapter_boundary_test.exs test/residency_schedule/importer/import_preview_test.exs
```

Result: **16 tests, 16 failures**, exit status 2. Every failure was an
`UndefinedFunctionError` for the not-yet-implemented CSV/QGenda/JSON adapters or
`Preview.prepare/3`; fixtures and database setup were operational.

Frozen test SHA256 values before implementation:

| Path | SHA256 |
| --- | --- |
| `test/residency_schedule/importer/adapter_boundary_test.exs` | `3e203e3dfb5d2e8ee826e22088a714b388bcabf329f9a5467b08db607bcb8ac0` |
| `test/residency_schedule/importer/import_preview_test.exs` | `0f3a487633b9bf8fe2ad172a19e68cdad07d8ee4bd9036b4b952bd711ae326f0` |

## Initial implementation green

After the implementer formatted its owned source files and passed test-environment
compilation with warnings as errors, the runner executed importer and builder
directories, all three detailed-schedule context test files and the upload
LiveView tests. Result: **14 doctests, 361 tests, zero failures**. Both accepted
test hashes above remained unchanged.

The existing audit log has 351 entries, 155 with historical violation flags,
and its last timestamp is October 20. It did not gain task-specific events;
native audit hook activation is therefore unverified. Direct ownership and final
diff/test hashes are checked independently. `git diff --check` passed.

The full ExUnit suite then passed: **217 doctests, 1,756 tests, zero failures**
in 62.2 seconds. This run preceded the small JSON scope correction below.

## Review regression: JSON header scope

Independent review found that explicit empty or partial JSON header dates could
exclude assignment facts from the declared import scope. The test writer added
the header/assignment-date union regression and enabled all three adapter
doctests, formatted the tests, and obtained renewed review acceptance.

Renewed boundary-test SHA256:
`5603aa7d7f2804dbdfa61298ca538f7e269d8a72d1a4367e50520c033b2e45e9`.
The preview-test hash remained unchanged.

Before correction, the runner executed the boundary test file: **3 doctests,
11 tests, one failure**, exit status 2. The new regression failed because explicit
empty headers yielded `[]` instead of the assignment date `2026-12-28`.

## Final source verification

The implementer corrected JSON scope to use the sorted unique union of validated
explicit headers and actual assignment dates. Final focused execution of the
two contract files passed: **3 doctests, 17 tests, zero failures**.

Read-only final checks passed:

- `MIX_ENV=test mix compile --warnings-as-errors`.
- `mix format --check-formatted`.
- `MIX_ENV=test mix credo --strict`: 329 source files checked, no issues.
- `mix deps.unlock --check-unused`: no unused lock entries.
- Fresh `mix hex.audit`: no retired or security advisory Hex packages found.
- `git diff --check`.

Credo initially found one alphabetization issue in a new test alias group. The
test writer corrected and formatted only that group; no assertions changed.
The runner then repeated both contract files and read-only formatting/Credo,
all passing. Final test SHA256 values:

| Path | SHA256 |
| --- | --- |
| `test/residency_schedule/importer/adapter_boundary_test.exs` | `5603aa7d7f2804dbdfa61298ca538f7e269d8a72d1a4367e50520c033b2e45e9` |
| `test/residency_schedule/importer/import_preview_test.exs` | `bcf0c9ce8c309d0bd5eae1393b1c49d4f3175a27a6326a6932f46fc6d86d7cde` |

The full-suite pass above preceded only the local header-union correction and
mechanical test-alias reorder. The final affected adapter/preview tests passed
after those changes; the entire unchanged suite was not repeated. The dependency
lock remains byte-identical to the baseline. No deployment or data migration was
performed.

## Independent acceptance

The independent reviewer accepted the tests before implementation and reviewed
all changed source, new modules, documentation and final test hashes above.
The original accepted assertions remain intact. The additional header-scope
regression was accepted and demonstrated red before its correction; the later
alias-order correction changes no behavior or expected result.

The header-scope finding is resolved: JSON scope includes every assignment date
along with source-only header dates. Legacy QGenda fingerprint construction,
CSV update semantics and builder date normalization are preserved. New JSON
previews remain read-only and are rejected by the detailed-assignment commit API.
No actionable implementation or documentation finding remains after the runner's
final affected-test and static-check results.

Current Hex advisory retrieval reported no retired or vulnerable Hex packages;
this is not a comprehensive OS, runtime, browser, Ruby or vendor audit. Native
audit-hook activation remains unverified, as noted above. These limits are
reported rather than inferred from installed hook configuration. This acceptance
covers the local adapter-boundary delivery, not production deployment or schema
migration.
