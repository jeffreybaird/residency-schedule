# PR #98 CI verification

Recorded November 10, 2026. Local isolated test-database evidence only; no
production deployment, migration, backfill or credentials were accessed.

## Environment and unchanged baseline

- Starting commit: `d801c557c90884a3d2101057eb8fb9a2ea5b8228` on
  `codex/coverage-calendar-source-metadata`.
- `deps` and `_build` copied from `/workspace/residency-schedule`, without mutable
  dependency/build symlinks. Runtime selected with `/workspace/.setup/activate.sh`.
- Managed environment status was refreshed; current network policy was enforced.
  No secrets or outbound identities were configured in its status response.
- Local PostgreSQL was stopped after environment resume. Its existing local
  cluster was started; no development database was queried or migrated.
- Every Mix/database command explicitly selected `MIX_ENV=test` and
  `MIX_TEST_PARTITION=pr98ci`. Configured and actual `SELECT current_database()`
  both confirmed `residency_schedule_testpr98ci` before migrations.
- The new isolated test database was created and existing migrations applied.
- Starting lock SHA256:
  `52e797eba31a48eee06a6a235a41c40b5b33e277ee7a4edfc1bed6ade8131136`.

The reported CI failure location was first executed without source/test edits:

```sh
MIX_ENV=test MIX_TEST_PARTITION=pr98ci mix test test/residency_schedule/importer/import_preview_test.exs:34
```

Result: **one test, zero failures, five excluded**, 0.9 seconds, seed `981605`,
exit zero. The entire existing `import_preview_test.exs` module then passed:
**six tests, zero failures**, 1.5 seconds, seed `331990`, exit zero. These local
green results do not establish the cause of the reported CI failure.

The unchanged, unfiltered whole-suite command then ran:

```sh
MIX_ENV=test MIX_TEST_PARTITION=pr98ci mix test
```

Result: **302 doctests, 1965 tests, zero failures**, 201.4 seconds, seed `142265`,
exit zero. Existing noisy profiling output, reference-range warnings and the
intentional authentication logging sentinel remained visible in
`/tmp/pr98ci-baseline-full.log`. The reported CI failure did not reproduce in
the line-specific, module or full-suite runs. No source or test was changed to
obtain these results, and no cause is inferred from a local green run.

A subsequent CI rerun again reported failures in tests using async database
fixtures, justifying a
second local full run with the CI-like two-scheduler setting:

```sh
ERL_FLAGS='+S 2:2' MIX_ENV=test MIX_TEST_PARTITION=pr98ci mix test
```

An explicit runtime check reported two schedulers and confirmed the same isolated
database. Result: **302 doctests, 1965 tests, zero failures**, 274.9 seconds,
seed `347516`, exit zero; ExUnit reported `max_cases: 4`. Source, tests and lock
remained unchanged. A scoped direct-PostgreSQL sampler was started with a
one-second interval, but collecting its result revealed that a `psql` subprocess
exceeded its eight-second diagnostic timeout and the sampler exited 1.
`/tmp/pr98ci-blockers.log` remained empty, so continuous sampling and any live
blocking chain were not established. An earlier single scoped snapshot had no
blocked application connections; neither result proves an absence of contention.
The diagnostic failure did not change or interrupt the test process.

Separately, the frozen upgraded dependency branch produced seven existing
fixture/connection timeout failures; those details are recorded in its advisory
verification. The user-approved next step is a narrow test-only isolation fix,
retaining the existing concurrent regression and all assertions/timeouts.

## Approved fixture correction

The writer isolated only the common CSV preview fixture in a reserved roster year
while retaining its resident and every preview/snapshot/commit assertion. The
fixture-isolation module now runs synchronously with other modules; its two
internal concurrent checkouts and barriers remain intact. No runtime code or
timeout changed. The reviewer accepted these frozen hashes:

- `import_preview_test.exs`:
  `a454ea6bff9359c6470b6bf4ceff8bb115797c795a7a5fc7afca5c44b1496f38`.
- `schedule_fixture_isolation_test.exs`:
  `eed8e1b68ba180980c2ed44f2d926077a611f54b562b83da0f19938bef59d3d1`.

Focused ImportPreview, fixture-isolation and MCP Toolbox verification passed:
**five doctests, 13 tests, zero failures**, 0.8 seconds, seed `592532`, exit zero.
Read-only formatting, warnings-as-errors compilation, strict Credo (378 files,
69 checks, no issues), unused-lock and whitespace checks passed. A fresh audit
still reported the two known dependency advisories below, exit 1; their separate
fix was not folded into PR #98 or suppressed. The final frozen command was:

```sh
MIX_ENV=test MIX_TEST_PARTITION=pr98ci mix test
```

At the default four schedulers it passed **302 doctests, 1965 tests, zero
failures**, 164.2 seconds, seed `48599`, exit zero. Both accepted test hashes and
the original lock hash were unchanged afterward. Complete output is retained
locally at `/tmp/pr98ci-fixed-full.log`. No source/test edits or other Mix jobs
overlapped this final whole-suite run.

## Fresh security audit

Fresh `mix hex.audit` found two advisories. A separate SARIF audit explicitly
confirmed exit 1 and preserved metadata in `/tmp/pr98ci-audit-baseline.sarif`.

| Dependency | Installed | Advisory | Severity and reported trigger |
| --- | --- | --- | --- |
| `ecto` | 3.14.2 | EEF-CVE-2026-118391 / CVE-2026-118391 / GHSA-cxjx-vmm2-qr8r | High; unbounded query cache growth from interpolated JSON paths and splice lists. |
| `phoenix_html` | 4.3.0 | EEF-CVE-2026-117645 / CVE-2026-117645 | Medium; attribute injection via unvalidated attribute names in `attributes_escape/1`. |

The source owner fetched primary Hex package metadata and upstream changelogs:
Ecto is affected from 3.4.0 through versions below 3.14.3, patched in 3.14.3;
Phoenix.HTML is affected from 1.0.0 to below 3.3.5 or from 4.0.0 to below 4.4.0,
patched on the installed major in 4.4.0. Sources:
`https://hex.pm/api/packages/ecto` and
`https://hex.pm/api/packages/phoenix_html`. Reported application searches found
no direct `json_extract_path`, `splice` or `attributes_escape` calls, but this is
not proof that transitive framework paths cannot expose the vulnerabilities.
Findings were immediately routed to the orchestrator; compatible upgrades are
being handled on a separate advisory branch. PR #98 dependencies remain unchanged
and none of these advisories were suppressed.

Native source/test hook activation is unverified. The runner makes no source or
test edits; accepted-test hashes and independent review provide workflow evidence.
