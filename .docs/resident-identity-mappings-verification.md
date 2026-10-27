# Resident identity mappings verification

Recorded October 27, 2026. This records local development/test work only;
no production service, deployment, database or credentials were accessed.

## Baseline and environment

- Starting source: merged `main` commit `1cec070` (advisory PR #89).
- Own `deps` and `_build` directories were copied from the sibling advisory
  checkout; no mutable dependency/build symlinks were used, and the sibling and
  original planning worktrees were not modified.
- Runtime selected with `/workspace/.setup/activate.sh`: Elixir 1.19.5 and
  Erlang/OTP 28.5.0.7. A direct read confirmed the test database is
  `residency_schedule_testidentity` on PostgreSQL 17.11.
- Database and Mix commands used sandboxed additional network permissions for
  local sockets and the ordinary configured proxy.
- Setup correction: the first `mix ecto.create/migrate` commands omitted
  `MIX_ENV=test`. They applied the already-existing additive provenance migration
  `20261021180835` to the preexisting local development database. This was a
  local setup side effect, not production work or identity-mapping evidence.
  No rollback was attempted. Subsequent database setup explicitly used
  `MIX_ENV=test MIX_TEST_PARTITION=identity` and created/migrated the isolated
  test database. All authoritative tests below used the identity test partition.
- Baseline lock SHA256:
  `0ca292f932368c6241c5b8208cad03873047b992a672f6c6db3a54cc3d49390d`.

The runner executed explicit existing test paths before new identity tests or
source implementation:

```sh
MIX_ENV=test MIX_TEST_PARTITION=identity mix test test/residency_schedule/importer/resident_linker_test.exs test/residency_schedule/importer/qgenda_crosswalk_test.exs test/residency_schedule/importer/qgenda_uploaded_crosswalk_test.exs test/residency_schedule/importer/qgenda_crosswalk_rejection_test.exs test/residency_schedule/importer/qgenda_preview_test.exs test/residency_schedule/source_provenance_test.exs test/residency_schedule/contexts/detailed_schedule_integrity_test.exs test/residency_schedule/importer/integration_test.exs test/residency_schedule/schedule_builder test/residency_schedule_web/live/qgenda_upload_test.exs test/residency_schedule_web/live/qgenda_save_lifecycle_test.exs
```

Result: **7 doctests, 233 tests, zero failures**, 6.5 seconds, exit zero,
seed `974787`. Fresh `mix hex.audit` exited zero: “No retired or security advisory
packages found.” This is a current Hex advisory check, not a comprehensive
OS, runtime, browser or vendored dependency audit.

## Accepted contract and authoritative red

The reviewer accepted the following test hashes before implementation:

| Path | SHA256 |
| --- | --- |
| `test/residency_schedule/contexts/identity_mappings_test.exs` | `a540462bbac02e00c594d56a1de5dd46ccc90bfd9c0645cf1007d441f49519ac` |
| `test/residency_schedule/repo/migrations/add_source_identity_mappings_test.exs` | `3afaaabeb63cf660018b2c5d774e25bc62af1c557a899d0fa470b49a0b67094b` |

The runner confirmed both exact hashes and directly checked that the connected
database was `residency_schedule_testidentity` before executing:

```sh
MIX_ENV=test MIX_TEST_PARTITION=identity mix test test/residency_schedule/contexts/identity_mappings_test.exs test/residency_schedule/repo/migrations/add_source_identity_mappings_test.exs
```

Result: **19 tests, 19 failures**, exit 2, 2.2 seconds, seed `904820`. Failures
were `UndefinedFunctionError` for the not-yet-implemented identity mapping
context or migration API. Test fixtures and database access were operational;
no unrelated setup failure was used as expected-red evidence. The implementer
was released only after this run and reviewer acceptance.

## Implementation verification

After the original red and implementation release, the reviewer accepted two
additional direct database checks (approved-current uniqueness and raw schedule
deletion preserving snapshots while nulling live foreign keys). The expanded
intermediate core contract SHA256 was
`3fadc0742eabae1ca9a2e0107be4fa92d0cfd88137390da4457923694cecf26b`;
the migration contract hash was unchanged. This historical intermediate
contract contained 20 core tests plus one migration test; the final contract
below adds two regressions and public doctests.

First expanded-contract run confirmed the test database before applying migration
`20261027150732`: **21 tests, two failures**, seed `691289`, exit 2. One fixture
insert collided with the preexisting detailed activity identity uniqueness
constraint; the test writer corrected the fixture to reuse the existing activity.
The direct schedule-delete check exposed a retained live membership reference;
the implementer corrected the migration. Neither failed assertion was removed
by the runner.

Initial static checks found formatting and strict Credo issues in new source
and tests and were returned to their owners. A fresh Hex audit passed with no
retired or security advisory packages. Owners corrected these issues before the
final checks below.

After confirming `residency_schedule_testidentity` and latest migration
`20261027150732`, the runner rolled back and reapplied only that new migration
to verify its corrected independent membership foreign key locally. No older
migration or development database was rolled back.

The reviewer accepted renewed core contract SHA256
`c37974557d5216ff03e1f62e17c56bc29bdd561be803c176c630ced8ad8cb181`
(migration hash unchanged), including the fixture correction, formatting/static
cleanup, public doctests, and two new regression tests. Before the corresponding
source fixes, an authoritative run returned **6 doctests, 23 tests, two expected
failures**, seed `965467`, exit 2. The failures demonstrated an approved alias
incorrectly overriding new exact-name evidence and fresh review being held after
an old target was removed. The earlier fixture and direct-delete checks passed.

## Final frozen verification

The reviewer accepted the final alias-order-only test correction and independently
reviewed source and documentation. Final test hashes were checked before the
last full run and remained unchanged afterward:

| Path | SHA256 |
| --- | --- |
| `test/residency_schedule/contexts/identity_mappings_test.exs` | `4e37cba09d40e064d472f81b2300f2600ea5bf46acef9c58c73b6716a8bf41ab` |
| `test/residency_schedule/repo/migrations/add_source_identity_mappings_test.exs` | `3afaaabeb63cf660018b2c5d774e25bc62af1c557a899d0fa470b49a0b67094b` |

The targeted identity contract passed with **6 doctests, 23 tests, zero failures**,
seed `344961`, exit zero, before behavior-preserving static cleanup. The first
whole-suite run also passed (**226 doctests, 1792 tests**, seed `364270`), but
owners made static corrections while that process was running. The authoritative
final run freshly compiled those corrections and used the genuine unfiltered
whole-suite command:

```sh
MIX_ENV=test MIX_TEST_PARTITION=identity mix test
```

Result: **226 doctests, 1792 tests, zero failures**, 87.2 seconds, seed `988790`,
exit zero. Output was redirected to `/tmp/residency-identity-final-suite.log`
to contain existing noisy reference-range warnings and profiling output;
test selection and behavior were unchanged.

All final read-only checks exited zero:

```sh
MIX_ENV=test MIX_TEST_PARTITION=identity mix format --check-formatted
MIX_ENV=test MIX_TEST_PARTITION=identity mix compile --warnings-as-errors
MIX_ENV=test MIX_TEST_PARTITION=identity mix deps.unlock --check-unused
MIX_ENV=test MIX_TEST_PARTITION=identity mix credo --strict
MIX_ENV=test MIX_TEST_PARTITION=identity mix hex.audit
git diff --check
```

Strict Credo checked 341 files with 69 checks and found no issues. The fresh
Hex audit reported no retired or security advisory packages. The lockfile
SHA256 remained the baseline hash above, retaining the merged advisory fixes.
The unused-lock check is the read-only equivalent of the precommit alias's
`deps.unlock --unused`; it exited zero and left the lockfile unchanged.

Limits: these are local isolated test-database checks, including legacy-populated
migration and omitted-column compatibility tests. No production migration,
production backfill, deploy, merge, browser walkthrough, comprehensive external
dependency audit, or native source/test hook activation was verified. Role
ownership and accepted-test hashes were followed independently of hook activation.

## Executable documentation follow-up

The follow-up requires real happy-path executable examples for the new public
identity APIs, including database-backed functions. The reviewer accepted the
fixture helper SHA256
`50e1b370f0d3b41170a40da4492903714b1ee7610c5eb70c464f393d244dfc9a`
and corrected doctest contract SHA256
`911c562545384b4a133b1826475c50dc5d80dcd88e5127e72b16b189b8f7a7c9`
before source documentation edits. The runner reconfirmed database
`residency_schedule_testidentity` and these hashes. An initial overly narrow
Release doctest filter caused a compilation-only registration error and was
corrected by the test writer and reaccepted; it was not used as formal red.

The authoritative isolated doctest-contract run returned **4 doctests, two
tests, one expected failure**, seed `282739`, exit 2. The assertion identified
18 public functions lacking executable examples; the real scoped-data fixture
smoke test and existing Release examples passed. Source documentation work was
released after that assertion red. A separate migration doctest registration
load-order error was returned to the test writer; it was not treated as expected
behavioral red. The orchestrator subsequently excluded incidental migration
doctest registration from this documentation follow-up. Migration source and
behavioral tests were restored exactly to the accepted committed version,
retaining all migration compatibility assertions and the original test hash
`3afaaabeb63cf660018b2c5d774e25bc62af1c557a899d0fa470b49a0b67094b`.

The final accepted fixture and doctest-contract hashes above remained unchanged;
the original core identity test retained hash
`4e37cba09d40e064d472f81b2300f2600ea5bf46acef9c58c73b6716a8bf41ab`.
The final batch executed:

```sh
MIX_ENV=test MIX_TEST_PARTITION=identity mix test test/residency_schedule/contexts/identity_mappings_doctest_test.exs test/residency_schedule/contexts/identity_mappings_test.exs test/residency_schedule/repo/migrations/add_source_identity_mappings_test.exs test/residency_schedule/release_test.exs
```

Result: **33 doctests, 27 tests, zero failures**, 1.8 seconds, seed `735825`,
exit zero. All examples use synthetic test data inside the isolated test
database. The reviewer accepted the fixture, final registration, restored
migration contract, and source documentation changes.

Read-only formatting, warnings-as-errors compilation, strict Credo, unused-lock
check, fresh Hex advisory audit, and diff whitespace check all passed. Final
Credo checked 343 files with 69 checks and found no issues. The fresh audit
reported no retired or security advisory packages; lockfile SHA256 remained
`0ca292f932368c6241c5b8208cad03873047b992a672f6c6db3a54cc3d49390d`.
The follow-up changes documentation, doctest registration, and synthetic fixtures;
runtime function bodies and the migration are unchanged. Targeted verification
was therefore used for this follow-up; the earlier whole-suite result remains
the runtime implementation baseline, without claiming a new whole-suite run.
