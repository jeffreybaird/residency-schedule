# QGenda detailed activities verification

Authoritative runner evidence for milestone two, 2026-10-02 (user timezone).
No source or test edits were made by the runner. Local runtime: Elixir 1.19.5,
Erlang OTP 29. Mix commands required escalation for local TCP and test database
access. No production or development schedule records were written.

## Red evidence and test contract

All commands below used `MIX_ENV=test mix test` with the named paths and exited 2.

| Tests | Initial result | Failure demonstrated |
| --- | --- | --- |
| `test/residency_schedule/contexts/detailed_schedules_test.exs` and `test/residency_schedule_web/live/qgenda_details_test.exs` | 22 tests, 22 failures; seed 945580 | Missing persistence API and daily-detail UI |
| `test/residency_schedule_web/live/qgenda_save_lifecycle_test.exs` | 4 tests, 4 failures; seed 537847 | Missing save lifecycle and identity-protection behavior |
| `test/residency_schedule/contexts/detailed_schedule_integrity_test.exs` | 2 tests, 1 failure; seed 86585 | Conflicting incoming source coordinates were accepted; FK restriction already passed |
| `test/residency_schedule_web/live/qgenda_protected_deletion_test.exs` | 3 tests, 3 failures; seed 465277 | Protected schedule deletion raised a constraint exception instead of returning a safe error |
| `test/residency_schedule/contexts/detailed_schedule_empty_import_test.exs` | 1 test, 1 failure; seed 210681 | A zero-match preview incorrectly created an empty protective batch |

The reviewer accepted each behavior contract before its corresponding source
implementation. Two revocation tests needed an additional administrator to
satisfy the existing last-admin invariant before testing revocation. The test
writer made those prerequisite corrections and alias-order corrections with
renewed reviewer acceptance; assertions were not weakened.

An early run encountered a generated migration before its contents were filled
in. After confirming all three detail tables were absent in the **test** database,
the runner removed only its empty ledger entry, version `20261003023510`, then
reran the completed migration. No development or production migration ledger
was altered. Integrity-specific red evidence above was recorded afterward.

## Final green checks

- `MIX_ENV=test mix test`: exit 0, **174 doctests, 1,343 tests, 0 failures**,
  seed 78283, 34.1 seconds.
- After the final alias-only fixture correction, all six milestone-two test
  files were rerun: exit 0, **32 tests, 0 failures**.
- `MIX_ENV=test mix format --check-formatted`: exit 0 against final files.
- `MIX_ENV=test mix compile --warnings-as-errors`: exit 0.
- `MIX_ENV=test mix deps.unlock --check-unused`: exit 0, without lockfile edits.
- `MIX_ENV=test mix credo --strict`: exit 0 after final corrections;
  239 files and 2,018 modules/functions, no issues.

## Actual export persistence, rollback only

The actual XLSX, ignored uploaded crosswalk, and production roster snapshot were
used inside an explicitly checked-out SQL sandbox in the **test** database.
The public preview and commit APIs were exercised. Real names and assignments
existed only within this rolled-back test transaction; logs contained aggregate
counts only. The application did not save anything to development or production.

| Check | Result |
| --- | ---: |
| First import activities | 7,779 |
| Source/provenance records | 7,779 |
| Import batches | 1 |
| Linked note records | 206 |
| Unmatched assignments skipped | 866 |
| Repeated import inserted | 0 |
| Repeated import existing | 7,779 |
| First commit duration on this machine | 360 ms |
| Batches after sandbox rollback, checked in a fresh checkout | 0 |

The first diagnostic run used an incorrect SQL cast for the aggregate note
count; its `after` block rolled back the sandbox. The corrected run used
`cardinality(notes)`, asserted all counts, verified rollback, and exited 0.

## Accepted final SHA-256 hashes

```text
6350b62ae285a9d575442955031f9e1efe93d7a3a805ab59b197d9b2ad7c2e75  test/residency_schedule/contexts/detailed_schedule_empty_import_test.exs
a1a19c35600a3ec34f3ca6ec14eee765391893ce809f76d56f7fd2ddc7111757  test/residency_schedule/contexts/detailed_schedule_integrity_test.exs
64afaf83b3cfa491ac946e1c0542a508c5702e433b6f93b37054f8635d3c6860  test/residency_schedule/contexts/detailed_schedules_test.exs
1a8140edbb7a44c0ecc8991e698be0ee09dad22a50bd002075b2e1c5b1a4c442  test/residency_schedule_web/live/qgenda_details_test.exs
34ffb5c3e2f93b3ac4ce038b1acf8482cb7952507471bd770b9452a549f4b6e8  test/residency_schedule_web/live/qgenda_save_lifecycle_test.exs
8cec51aad95e7262bd566aca6af8627f9d84ac12e2a1d492665bbf47bfacad5b  test/residency_schedule_web/live/qgenda_protected_deletion_test.exs
d433269b61056c42be72e47b90c6c71a302e6da215342ae06afc1f52e5131372  test/support/qgenda_detail_fixtures.ex
```

## Security scope

See [the security review](qgenda-security-review.md) for independent advisory
review, including pre-existing runtime findings. Passing functional checks does
not establish a clean runtime or production deployment. No deployment was
performed as part of this verification.
