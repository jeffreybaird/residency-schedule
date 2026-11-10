# PR #102 merge verification

Recorded November 10, 2026. Merge validation combines feature head
`62e1bbc4c3e8afd7f1d4031dd353cb0293516e4d` with `main`
`b45a6ab543bf393181229c37e78da596f9bab2c6`. The add/add approved-differences
document was resolved to the feature-head bytes, preserving the main material
and the October 29 section. Runtime/source, configuration, assets and lock bytes
remain identical to the feature head. Other incoming changes are four existing
verification records and two reviewed fixture-isolation fixes; no new source,
test, assertion or timeout change was made.

The reviewer accepted the merged 247-file tracked-test manifest SHA256
`e441b91297b012fe6c6025cf8963ec68b7a5fd4b06b9c7c7b2480ddd0a72a786`.
The runner regenerated and verified it before and after checks. Lock SHA256 stayed
`52e797eba31a48eee06a6a235a41c40b5b33e277ee7a4edfc1bed6ade8131136`.

Independent copied dependency/build directories were used. All Mix/database
commands selected `MIX_ENV=test MIX_TEST_PARTITION=pr102merge` under
`/workspace/.setup/activate.sh`. Configured and actual `SELECT current_database()`
confirmed `residency_schedule_testpr102merge` before this new isolated database
was migrated. No development/production database, deployment, backfill or
application consumer switch was used.

```sh
MIX_ENV=test MIX_TEST_PARTITION=pr102merge mix test test/residency_schedule/effective_schedule/v2_evidence_test.exs test/residency_schedule/effective_schedule/v2_policies_test.exs test/residency_schedule/effective_schedule/v2_doctest_test.exs test/residency_schedule/effective_schedule/acceptance_test.exs test/residency_schedule/effective_schedule/comparison_test.exs test/residency_schedule/effective_schedule/normalize_test.exs test/residency_schedule/effective_schedule/effective_schedule_test.exs test/residency_schedule/release_compare_test.exs test/residency_schedule/observability_test.exs test/residency_schedule_web/operation_tracing_test.exs
```

Result: **21 doctests, 144 tests, zero failures**, 17.7 seconds, seed `471494`,
exit zero. This includes the owning v2 evidence and policy assertions, v2
doctests, acceptance/comparison/normalization, service/release behavior and
aggregate-only observability/privacy checks. Read-only formatting,
warnings-as-errors compilation, strict Credo (394 files, 69 checks, no issues),
unused-lock and whitespace checks passed.

A fresh Hex audit exited 1 with two known findings: Ecto 3.14.2 high
EEF-CVE-2026-118391 / CVE-2026-118391 / GHSA-cxjx-vmm2-qr8r (interpolated
JSON-path/splice query-cache growth, fixed in 3.14.3), and Phoenix.HTML 4.3.0
medium EEF-CVE-2026-117645 / CVE-2026-117645 (unvalidated attribute-name
injection, fixed in 4.4.0 on the installed major). Compatible upgrades remain
separate in [PR #103](https://github.com/jeffreybaird/residency-schedule/pull/103);
neither finding was suppressed or upgraded here.

No new whole-suite run or performance benchmark was performed for this
runtime-identical merge. Earlier feature whole-suite/performance results remain
historical evidence, not fresh validation. Phase 3 readiness is still unresolved;
this merge does not approve new reads for application consumers. Native hook
activation is unverified; accepted hashes, role ownership and independent review
provide workflow evidence.
