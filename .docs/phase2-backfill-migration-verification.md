# One-shot Phase 2 backfill migration verification

Recorded October 28, 2026. Local isolated test-database work only; no
production access.

## Change

Migration `20261028190000_run_phase2_backfills` runs the four Phase 2
backfills once during `Release.migrate()` on the next deployment: source
provenance, identity observations, legacy task seeding plus classifications,
and timings, in that order, stopping at the first error. The DDL transaction
and migration lock are disabled because each backfill commits one bounded
transaction per batch under the existing write lock. `up/0` honours
`:run_phase2_backfills_on_migrate` (true in `config/config.exs`, false in
`config/test.exs`) so test databases are never seeded by migration; `run/0`
is unconditional and `down/0` retains the additive data. The manual
`Release.backfill_*` commands remain the verification and rerun path, now
documented in `DEPLOY.md` with a deploy-user command that reads the managed
`runtime.json` without shell expansion.

## Workflow evidence

Accepted contract (reviewer-accepted before implementation, revised twice with
renewed acceptance: the config guard after the implementer found that
`seed_legacy` would seed every test database, and a shared loader in
`test/test_helper.exs` after the reviewer reproduced a module-definition race
between the two test files' loaders):

| Path | SHA256 |
| --- | --- |
| `test/residency_schedule/repo/migrations/run_phase2_backfills_test.exs` | `9cfb1d86c0e3bfb2be0f3c89532211874ed7adf3c07834d4ed6ad90a3af77926` |
| `test/residency_schedule/repo/migrations/run_phase2_backfills_doctest_test.exs` | `21d9bfc24fdc0bb6149a3ce77bb6c9558ef7c1e1fd39a2242a9e5c9237209fbf` |
| `test/support/migration_doctests.ex` | `fda1385f9ba923c256008d8f083f1eb909c2dac4ffc04d3599c6d1a7c6ab7ee8` |
| `test/test_helper.exs` | `ea73f36a6088ff29eeb216fc2c3001a4ef2bb91b7f852843311070575e3a830a` |

Red: 11 tests, 11 `UndefinedFunctionError` failures for the absent migration
module. Green on the `timing` partition (`residency_schedule_testtiming`,
migrated under the test flag with `activity_types` empty afterwards):
targeted **1 doctest, 13 tests, zero failures** on the default seed and seed
1; full unfiltered suite **278 doctests, 1866 tests, zero failures** twice
(seeds `132388`, `452369`). An earlier set of three full runs on the
pre-loader-fix contract was green twice and once hit the pre-existing
`schedule_fixture_isolation_test` deadlock-detection failure while another
`mix test` was running concurrently; it did not recur. Format,
warnings-as-errors compile, strict Credo (2943 modules/functions, no issues),
unused-lock check, Hex audit and whitespace check all exited zero. The
reviewer accepted the final diff.

## Security advisory

The reviewer's fresh `mix hex.audit` found `bandit 1.14.0` affected by
EEF-CVE-2026-116078 (CVE-2026-116078, GHSA-pxjf-g536-7r93, HIGH: HTTP/2
request bodies of 1-byte DATA frames amplify memory use), patched in 1.14.1
published October 28, 2026. The endpoint already disables HTTP/2 in
`config/config.exs`; the upgrade was applied as a lock-only change (commit
`8f6b5e1`), the HTTP protocol security tests passed, and the audit now
reports no advisories. Limits: Hex registry data only; OS, runtime, browser
and npm packages are not covered.

## Limits

No production migration or backfill was executed from this session. The
deployment that applies this migration will run the backfills with the
managed configuration; its aggregate counts go to the private release
evaluation log, which the promotion removes on success, so verify afterwards
by rerunning the manual commands and confirming zero new rows.
