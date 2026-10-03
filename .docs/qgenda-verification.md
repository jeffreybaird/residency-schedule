# QGenda preview verification — 2026-10-02

Authoritative runner evidence for milestone one. Commands ran locally with
Elixir 1.19.5 / Erlang OTP 29; Mix required sandbox escalation for local TCP
PubSub and the test database. No source or test files were edited by the runner.

## Red evidence

- `MIX_ENV=test mix test test/residency_schedule/importer/qgenda_preview_test.exs test/residency_schedule_web/live/qgenda_upload_test.exs`
  exited 2: 16 tests, 15 failures, seed 933442. Failures demonstrated absent
  preview API and UI; the existing access-control check passed.
- `MIX_ENV=test mix test test/residency_schedule/importer/qgenda_crosswalk_test.exs`
  exited 2: 3 doctests, 6 tests, 2 failures. Missing malformed-crosswalk warnings
  and previous-name visibility failed before their fixes.
- `MIX_ENV=test mix test test/residency_schedule/importer/qgenda_note_sections_test.exs`
  exited 2: 1 test, 1 failure. Assignment-tag metadata leaked into notes before
  the section-boundary fix.

The reviewer accepted each contract before the corresponding implementation.
The pagination test subsequently required an accepted harness correction:
`LazyHTML.query/2` searches descendants, whereas `filter/2` only filters roots.
The row-count bounds and pagination assertions remained intact. Additional
workbook security tests passed against existing implementation protections.

## Final green evidence

- `MIX_ENV=test mix test`: exit 0, **174 doctests, 1,292 tests, 0 failures**,
  seed 549651, 30.8 seconds.
- `MIX_ENV=test mix format --check-formatted`: exit 0.
- `MIX_ENV=test mix compile --warnings-as-errors`: exit 0.
- `MIX_ENV=test mix deps.unlock --check-unused`: exit 0; no lockfile mutation.
- `MIX_ENV=test mix credo --strict`: exit 0; 226 files, 1,941 modules/functions,
  no issues. Three initial source findings were corrected by the implementer.
- `mix hex.audit`: exit 0, no retired packages. This only checks retirement;
  see [security review](qgenda-security-review.md) for current dependency and
  runtime advisories and limitations. This is not a clean-runtime security claim.

## Actual export reconciliation

Used `MIX_ENV=test mix run --no-start -e ...` to call `QgendaParser.parse/1`
and `QgendaPreview.build/3` with an in-memory roster and the existing ignored
crosswalk. The application was not started; no real data was written to any
database. Only aggregate output was recorded.

| Check | Result |
| --- | ---: |
| Total assignments | 8,645 |
| Matched assignments | 7,779 |
| Unmatched assignments | 866 |
| Matched residents / roster size | 31 / 32 |
| Missing residents | 1 |
| Linked resident notes | 206 |
| Header dates | 273 |
| Header range | 2026-09-28 through 2027-06-27 |
| Matched assignment range | 2026-09-28 through 2027-06-13 |
| Unknown tasks | 0 |
| Unlinked notes after footer fix | 0 |
| Phone-pattern matches in complete preview | 0 |
| Assignment Tags / Phone Numbers footer markers in preview | 0 |
| Source directory contact values checked / leaked | 43 / 0 |

These counts reconcile to the existing mapping; the header range correctly
includes the final dates even where no resident assignment exists. Contact
comparison used source directory columns D onward, rows 1951–1991, without
printing their contents.

## Accepted final SHA-256 hashes

Original parser tests and four fixtures retained their accepted hashes.
The UI harness hash changed only through reviewed test-writer corrections.

```text
58f2dd8fa9a1c56bbacc1799fb155532f1e5bdf5b3b3e7f0f41e6c6d7d2057c8  test/residency_schedule/importer/qgenda_crosswalk_test.exs
3fb38d15f3387b5d5c0cbb2bf59bd62b9dde4da330208b1e2ec1c9073da134bd  test/residency_schedule/importer/qgenda_note_sections_test.exs
c636f7c688082644450b3eb353dc130d5b61ee35d39ae36bc1a4435452c073d5  test/residency_schedule/importer/qgenda_preview_test.exs
a08df9ff42ec776ffeebde13d311859628b48cf59c8019ceee832232d402d92f  test/residency_schedule/importer/qgenda_workbook_security_test.exs
45e747d3e8a5dd8cd348963be54ef55bada70cb15eff3703b403b79f81f5ac19  test/residency_schedule_web/live/qgenda_upload_test.exs
25f995c4e3dae0d275f3ecdbdde7dc438d940a0c8652a5b2783a66330cdd094c  test/fixtures/qgenda/forged-expanded-size.xlsx
bef42ba8eef0bfe40ef6de968ff8b8caa6920c74289023ba97cbd3ea5c87ba6c  test/fixtures/qgenda/inline.xlsx
c27abda09b0fa704c3498994c53ed529989e598402f6da0b2c5f7f94085ccd2b  test/fixtures/qgenda/paginated.xlsx
5da2a05e794868daea926096c8e903cd0d8dc64fb77473969a029d1bfd115a66  test/fixtures/qgenda/shared.xlsx
```
