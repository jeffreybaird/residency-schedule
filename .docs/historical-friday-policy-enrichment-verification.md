# Historical Friday policy enrichment verification

Recorded November 10, 2026. Local isolated test-database validation only; no
production credentials, service, deployment, migration or backfill was accessed.

## Baseline and environment

Starting source: merged `main` commit
`d7888cfbf6abcfdc41808309c4621b594bc26805` after PR #103. Dependency/build
directories are physical copies from the fixed advisory checkout, not mutable
symlinks. Runtime selected with `/workspace/.setup/activate.sh`.

The authoritative runner's Mix/database commands explicitly selected `MIX_ENV=test` and
`MIX_TEST_PARTITION=fridayenrich`. Both configuration and actual
`SELECT current_database()` confirmed `residency_schedule_testfridayenrich`
before this new isolated test database was migrated. No development database
was queried or migrated. Starting lock SHA256:
`93fb45ce393dc4ce80c96f16e2673b8e5780b1d5600b18237a915f5339db1c1b`.

Before any new source/migration implementation, the existing baseline command ran:

```sh
MIX_ENV=test MIX_TEST_PARTITION=fridayenrich mix test test/residency_schedule/contexts/friday_policy_evidence_test.exs test/residency_schedule/contexts/task_mappings_test.exs test/residency_schedule/contexts/task_mappings_doctest_test.exs test/residency_schedule/effective_schedule/v2_evidence_test.exs test/residency_schedule/effective_schedule/v2_policies_test.exs test/residency_schedule/effective_schedule/acceptance_test.exs test/residency_schedule/effective_schedule/effective_schedule_test.exs
```

Result: **16 doctests, 108 tests, zero failures**, 19.0 seconds, seed `290783`,
exit zero. This checks existing Friday mapping evidence, classification/backfill
behavior, v2 evidence/policies and service acceptance. Default test scheduling
remained enabled; no worker-count or timeout override was used.

Fresh `mix hex.audit` in the same explicit test environment exited zero:
“No retired or security advisory packages found.” This is Hex-package advisory
coverage, not an OS/runtime/browser/vendored dependency scan.

No production-readiness or consumer-switch result follows from this local
baseline. Native source/test hook activation is unverified; role ownership,
accepted hashes and independent review provide recorded workflow evidence.

## Accepted backend contract and authoritative red

The reviewer accepted these exact hashes before implementation. The runner
checked them before and after the red run without any intervening test edit:

| Path | SHA256 |
| --- | --- |
| `test/residency_schedule/contexts/friday_enrichment_test.exs` | `40ad744c6a7abb0e1197166dece89a35d228bf0d73294a2887af600f38d42128` |
| `test/residency_schedule/repo/migrations/add_friday_policy_attestations_test.exs` | `74469175d77540bd7b8963be163f2e7583b5d7c4c9d20d137e28f72ece70b9d4` |
| `test/support/friday_enrichment_fixtures.ex` | `6c96e20a6babea734a86523760f5eea3ebb775f80e670ffebd41ae625e15ff29` |

After reconfirming actual database `residency_schedule_testfridayenrich`:

```sh
MIX_ENV=test MIX_TEST_PARTITION=fridayenrich mix test test/residency_schedule/contexts/friday_enrichment_test.exs test/residency_schedule/repo/migrations/add_friday_policy_attestations_test.exs
```

Result: **24 tests, 24 expected failures**, 6.7 seconds, seed `896941`, exit 2.
All failures were `UndefinedFunctionError` for the absent FridayEnrichment
preview/apply, release wrappers or migration SQL API. Existing fixtures and
database operations worked; no SQL constraint/setup or compilation failure was
used as red evidence. Backend source work was released only after this result.
Complete local output: `/tmp/fridayenrich-backend-red.log`.

The requested administrator page follows a separate UI test/red stage in the
same delivery. Final verification will wait for both backend and UI to be green
and frozen before running a fresh unfiltered default-parallel whole suite.

## First backend implementation verification

After another actual isolated-database check, the runner applied additive
migration `20261110190000` only to `residency_schedule_testfridayenrich`. All
three accepted backend hashes above remained unchanged. The same core/migration
command returned **24 tests, one failure**, 4.1 seconds, seed `157197`, exit 2.
Migration compatibility assertions and 22 other core tests passed. The remaining
test mutates retained member/person/schedule/activity/mapping facts and expects
one conflict; one mutation instead returned `not_applicable`. The finding was
returned to the source owner without changing any accepted assertion.
Complete local output: `/tmp/fridayenrich-backend-first.log`.

The source owner corrected candidate filtering so retained original anchors are
considered before strict validation. The reviewer accepted the added executable
documentation registration SHA256
`4744812a05f4e292541ae420b92320213fd5cd07dd3b8b0b787fc85acf4fc907`.
Core, migration and fixture contracts stayed unchanged. The next targeted run,
including that doctest registration, passed **10 doctests, 24 tests, zero
failures**, 4.3 seconds, seed `382932`, exit zero. Migration-helper loading
warnings remained visible; migration behavioral assertions passed.
Complete local output: `/tmp/fridayenrich-backend-second.log`.

This is intermediate green: the source owner subsequently reported a
behavior-preserving static cleanup before final freeze. Final backend/UI
verification must compile and test the final frozen source again.

## Administrator interface contract setup

The initial accepted UI test batch could not compile: the plain ExUnit
background-job integration module did not import `Phoenix.ConnTest.get/2`, which
the LiveView test macro requires. It exited 1 before behavioral tests ran. This
was returned to the test writer for a minimal import correction and renewed
review; it was not used as missing-feature red or permission to implement UI.
The actual isolated database and all four original UI contract hashes had been
verified. Local setup output: `/tmp/fridayenrich-ui-red.log`.

The reviewer reaccepted the import-only correction. The runner checked the final
UI contract hashes before and after the genuine feature red:

| Path | SHA256 |
| --- | --- |
| `test/residency_schedule/contexts/friday_enrichment_runner_test.exs` | `766f757bfc01f0c9bce7bb868ff90f751b268cde4d18e06c7dee9410eccf7172` |
| `test/residency_schedule_web/live/friday_policy_test.exs` | `7a9b1e9f223bc5fd15e91fcbbc9c61d3219a60cef756589e79d93e36151b899a` |
| `test/residency_schedule_web/live/friday_policy_background_test.exs` | `ccef954c6483b7f7781907fd21fd1bd4a9d9df0bf9e11d268b52b4412de51169` |
| `test/support/friday_enrichment_ui_fixtures.ex` | `a0a4efad9a7721d77163bb3c793cbc104b2d60b8293107dc4a8074ae761c6ad9` |

```sh
MIX_ENV=test MIX_TEST_PARTITION=fridayenrich mix test test/residency_schedule/contexts/friday_enrichment_runner_test.exs test/residency_schedule_web/live/friday_policy_test.exs test/residency_schedule_web/live/friday_policy_background_test.exs
```

Result: **11 tests, 11 expected failures**, 3.2 seconds, seed `858328`, exit 2.
Six failures were missing runner APIs. The missing route caused a 404 redirect
failure and three LiveView static-token connection failures; the administrator
navigation link was also absent. Existing fixture/SQL and compilation setup
worked. The UI source owner was released only after this result. Corrected
local output: `/tmp/fridayenrich-ui-red-corrected.log`.

## Combined backend and interface verification

The reviewer accepted runner doctest registration SHA256
`d95f015d6789232a2d9833657c9e42880de524025f655b42399e83083ad19095`.
The first combined core, migration, LiveView/background and registered-doctest
run returned **14 doctests, 35 tests, four failures**, 15.9 seconds, seed
`461270`, exit 2. Three LiveView assertions reached an unaliased `Repo` reference
in the test module. The background case exceeded `render_async/1`'s default
100ms wait during initial preview, before it created the PostgreSQL blocker.
The log did not establish the preview status after teardown, so no performance
cause was inferred. These findings were returned to the test writer/reviewer;
no business or SQL-barrier assertion was removed. Local output:
`/tmp/fridayenrich-combined-first.log`.

The reviewer accepted the explicit Repo alias and bounded five-second waits for
the newly asynchronous preview UI, without changing global test/Sandbox timeout
configuration or SQL barriers. Renewed LiveView/background hashes were
`dd0ff23666699157b827577dbd2186925cc3de9cf58e04d2d7b66d19e4a92671`
and `825ec0c234e6dc40cb3cd26a59f9d7bbd3c552a525209ea1b0c28a6f7db6308c`.
The corrected combined run returned **14 doctests, 35 tests, one failure**,
10.9 seconds, seed `464234`, exit 2. The real background-job case could not
click a disabled apply button after its initial preview async task finished.
The preview's actual status/result was not retained in that output, so the
failure was sent for explicit boundary diagnostics rather than attributed to a
short wait or worked around. Local output:
`/tmp/fridayenrich-combined-final.log`.

A reviewed temporary boundary-diagnostic run repeated seed `464234` and returned
**14 doctests, 35 tests, one failure**, 12.7 seconds, exit 2. It instead timed
out at the initial five-second async wait before reaching its diagnostic capture;
no preview-state conclusion followed. The temporary capture also referenced an
unavailable HTML library and was returned to the writer for correction rather
than treated as application evidence. The migration test's separate reviewed
runtime-loading cleanup preserved its SQL assertions. Diagnostic output:
`/tmp/fridayenrich-boundary-diagnostic.log`. Temporary diagnostics must be removed
before final acceptance.

A corrected, reviewed state diagnostic repeated seed `464234`: **14 doctests,
35 tests, one failure**, 12.3 seconds, exit 2. It established that the initial
preview changed from running to failed with public `:run_failed`, leaving no
preview token. Both scoped PostgreSQL snapshots showed eight idle application
connections and no blocking PIDs. The bounded printed state truncated the worker
stack, so it did not identify the underlying exception. This ruled out merely
stale button rendering; connection ownership/pool behavior was returned for
investigation without claiming an application or PostgreSQL-lock cause.
Local diagnostic output: `/tmp/fridayenrich-state-diagnostic.log`.

The final bounded diagnostic printed the worker stack separately without
truncation. With seed `464234`, it returned **14 doctests, 35 tests, one failure**,
11.6 seconds, exit 2. Before and after the wait, the preview worker was blocked
in `DBConnection.Holder.checkout_call` while authorizing its administrator,
before executing a PostgreSQL query. Eight application connections were idle
and had no blocking PIDs. This established Sandbox auto-ownership pool pressure
from the committed integration fixture's persistent processes, rather than a
PostgreSQL lock or stale UI result. The existing scoped chat-disable helper was
proposed for that single unrelated-chat fixture; no application lifecycle or
timeout change followed from the diagnostic. Output:
`/tmp/fridayenrich-checkout-diagnostic.log`.

The reviewer accepted the diagnostic-free fixture resource correction: disable
unrelated sticky chat with the existing restoring helper, and mount the second
real view after the monitored first-view departure while retaining the same
database barrier. A constrained run explicitly verified two schedulers and four
pool connections, then used the same combined seed `464234`. It returned
**14 doctests, 35 tests, one failure**, 16.1 seconds, exit 2. Preview now completed
and the actual background-worker barrier was reached; intentionally killing the
first view then propagated `:killed` through a linked test client/helper to the
test itself. This fixture-link setup failure was returned to the writer without
weakening job-survival or concurrency assertions. No default full suite ran.
Local output: `/tmp/fridayenrich-constrained-final.log`.

The reviewer accepted the minimal client-proxy unlink setup correction, retaining
the actual view hard-kill and monitored `:killed` reason. The diagnostic-free
background hash became
`c5bf8685422fd91e0789b7b6093e840c603fa230a5fde65d3f73ee2853ad20a0`.
The same seven-path combined command at seed `464234`, with `ERL_FLAGS='+S 2:2'`,
then passed **14 doctests, 35 tests, zero failures**, 7.1 seconds, exit zero.
The runtime had explicitly confirmed two schedulers/four pool connections and
reported normal `max_cases: 4`. Actual SQL barriers, cross-administrator busy
checks, view-departure survival, final counts and revocation checks all remained.
Local output: `/tmp/fridayenrich-constrained-green.log`.

Read-only format and warnings-as-errors compile passed. Strict Credo found five
test-only alias, SQL-literal and helper-shape issues; these were returned to the
writer for assertion-preserving corrections and renewed review before the full
suite. The unused-lock check and fresh Hex audit passed, with no retired or
security-advisory packages. The lock stayed at the fixed baseline SHA256 above.

## Final frozen verification

The reviewer accepted the mechanical test corrections without changing any
business or migration assertion. Final changed contract hashes:

- Core backend: `e831f73e0abbf830ecb33cf58f48c631021a07a4e7d789137d805bba9b435dc2`.
- Migration: `d0f43082728f815319fd951eca9fa257cf4ef64c6dc540556a76fa47881820a6`.
- UI fixture: `d7b18e89fee9e0df610aac03fa4d702181f7197f4af4d6a23b6d0ef366c56728`.
- Background integration: `c5bf8685422fd91e0789b7b6093e840c603fa230a5fde65d3f73ee2853ad20a0`.

Read-only format, warnings-as-errors compile and strict Credo all passed after
these corrections. Credo checked 410 files with 69 checks and 3331 modules/functions,
finding no issues. The unused-lock check, fresh clean Hex audit and whitespace
check also passed; dependency versions were unchanged.

Immediately before the full run, the runner hashed all tracked and unignored new
runtime/test/config/asset/migration inputs, sorting unique repository paths:

- 499 source/test inputs: `6936a50a58d165b4cdc112f563fdeea51722aa39fbb923d800e6dda3c6b95d8b`.
- 258 test inputs: `94deae1ee3022332ad32859e49732c948e7c23d142c14cb6fbbe247ba8d68883`.

The final unfiltered default-parallel command was:

```sh
MIX_ENV=test MIX_TEST_PARTITION=fridayenrich mix test --seed 464234
```

Result: **335 doctests, 2057 tests, zero failures**, 262.4 seconds, seed `464234`,
exit zero. ExUnit reported normal `max_cases: 8`; no worker-count override,
global timeout increase or test exclusion was used. Complete local output:
`/tmp/fridayenrich-final-full.log`. Existing profiling output and intentional
authentication logging sentinel remained visible.

The 499-input source/test manifest, 258-input test manifest and fixed lock hash
were regenerated afterward and matched exactly. Source/tests and lock stayed
frozen; root browser verification and independent Mix checks were already
complete. The deliberate existing scheduler-probe child remained part of the
tests, rather than an overlapping independent validation job.

This establishes local implementation verification, not production deployment,
enrichment execution, a completed Phase 3 comparison or approval to switch
consumers to v2. The legacy consumers remain authoritative.

## Separate browser evidence

Root separately verified Chromium at 390×844 and 1280×900 using a newly migrated
`residency_schedule_testfridaybrowser` partition, with actual database guard
before synthetic seeding. It checked login, administrator navigation/page,
disabled apply before preview, read-only preview of one eligible row, explicit
apply producing one attestation, reload retaining the last result, and repeat
producing zero new/one already attested. Root reported no overflow or JavaScript
errors. This deliberate browser fixture is separate from the authoritative
`fridayenrich` test partition and establishes no production operation.
The browser server was stopped and its disposable database was dropped afterward.

Local screenshots: `/workspace/artifacts/friday-policy-mobile-preview.png`,
`/workspace/artifacts/friday-policy-mobile-completed.png`, and
`/workspace/artifacts/friday-policy-desktop.png`.
