# PR #101 automatic merge verification

Recorded November 10, 2026. Automatic merge of feature head
`18580093b99d41b206acdba16347e710e138241e` with `main`
`7805d36fd82e57a7d272e0872eaf005521871076` changes no runtime/source,
configuration, assets or lock bytes. Incoming work contains three prior
verification records and the two reviewed fixture-isolation fixes. No conflict,
new test, runtime edit, assertion weakening or timeout change was needed.

The merged 242-file tracked-test manifest was accepted by the reviewer and
regenerated before/after verification, unchanged at SHA256
`5f106fea332fd1f932941035cad22bc08208ce922d99280ddef4bd9626f7901a`.
Lock SHA256 stayed
`52e797eba31a48eee06a6a235a41c40b5b33e277ee7a4edfc1bed6ade8131136`.

Own copied dependency/build directories were used. Every Mix/database command
selected `MIX_ENV=test MIX_TEST_PARTITION=pr101merge` under
`/workspace/.setup/activate.sh`. Configuration and actual `SELECT current_database()`
both confirmed `residency_schedule_testpr101merge` before this new isolated
database was migrated. No local development/production database, deployment or
backfill was used.

```sh
MIX_ENV=test MIX_TEST_PARTITION=pr101merge mix test test/residency_schedule/contexts/friday_policy_evidence_test.exs test/residency_schedule/contexts/task_mappings_test.exs test/residency_schedule/contexts/task_mappings_doctest_test.exs test/residency_schedule/repo/migrations/add_task_classifications_test.exs test/residency_schedule/effective_schedule/acceptance_test.exs test/residency_schedule/effective_schedule/effective_schedule_test.exs test/residency_schedule/strong_night_projection_test.exs
```

Result: **16 doctests, 84 tests, zero failures**, 24.7 seconds, seed `678389`, exit zero.
The owning Friday-policy test checks explicit contact-night policy evidence,
revision preservation and conservative classification outcomes; the selection
also covers catalogue/backfill doctests, migration compatibility, effective reads
and Strong night projection. Existing migration-helper loading warnings remained
visible. Read-only formatting, warnings-as-errors compilation, strict Credo
(380 files, 69 checks, no issues), unused-lock and whitespace checks passed.

Fresh Hex audit exited 1 with two known findings: Ecto 3.14.2 high
EEF-CVE-2026-118391 / CVE-2026-118391 / GHSA-cxjx-vmm2-qr8r (interpolated
JSON-path/splice query-cache growth, fixed in 3.14.3), and Phoenix.HTML 4.3.0
medium EEF-CVE-2026-117645 / CVE-2026-117645 (unvalidated attribute-name
injection, fixed in 4.4.0 on the installed major). Compatible upgrades remain
separate in [PR #103](https://github.com/jeffreybaird/residency-schedule/pull/103);
neither finding was suppressed or upgraded here.

No new full-suite run was performed for this runtime-identical automatic merge.
Earlier whole-feature evidence remains historical, not a new result. Native
hook activation is unverified; role ownership, accepted hashes and independent
review provide the workflow evidence.
