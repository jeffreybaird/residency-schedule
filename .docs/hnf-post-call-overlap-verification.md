# Highland Night Float / Post Call reconciliation

Reviewed October 13, 2026.

The annual CSV importer moves Highland Night Float (HNF) from its source Monday
start to Sunday. It previously retained the preceding Post Call's source Sunday,
creating contradictory assignments before persistence or rendering.

`HighlandPostCall.normalize/1` subtracts a resident's baseline HNF intervals from
their Post Call intervals. It retains nonoverlapping dates and all original
fields/IDs, splits an interior interval when necessary, and removes a fully
overlapped interval. All other rotation overlaps remain unchanged.

Annual parsing applies the rule per resident after date adjustment. Literal
date-update parsing retains its existing dates and validation. Shared rotation
projection applies the same rule to previously stored assignments before derived
Friday corrections and coverage. Coverage retains the original HNF identity;
incoming coverage does not additionally suppress a covering resident's Post Call.
Date/range queries filter after projection, so a shortened Saturday Post Call
does not appear in Sunday's result. Schedule cache calculation version is 2.

Annual builder saves apply the same normalization. Historical weekly schedule
loading recognizes a shortened Saturday-only Post Call only when that resident's
HNF starts the following Sunday. This preserves canonical source slots and the
existing rejection of ambiguous literal overlapping shifts. Literal builder/editor
saves retain their existing date behavior.

Historical stored rows and editor/raw APIs remain literal and editable. No
migration or production mutation is required: projected/effective reads correct
the old records after the updated application runs. Existing documented partial
projection outside a requested range remains unchanged.

## Accepted contracts

- `test/residency_schedule/importer/hnf_post_call_test.exs`:
  `293e7657fbc1ebb1ce11c8e07d2586d13f71589b63609bf41b48c8357de1bba1`
- `test/residency_schedule/hnf_post_call_projection_test.exs`:
  `c17c0043169ea0c25acb5af2b5cd6536344bd0f805fabffd909c240da9db441a`
- `test/residency_schedule/highland_post_call_test.exs`:
  `fd69e5e4897ffb234b783e6233da81de2b85628685abfa43e8176b4fc750d368`
- `test/residency_schedule/schedule_builder/hnf_post_call_test.exs`:
  `bd644891b642b62b10ca14f33dc2f832db1c878d9de5bca38fd05cb2bfc7943e`
- `test/residency_schedule/schedule_editor_test.exs`:
  `18e6c6f05b1435793f087d632d4eed38f6a620928940b8104783c0caa3a08425`

The independent reviewer accepted the first two files after authoritative red:
11 tests, six intended failures, five passing guards. An initial invalid
overlapping date-update fixture was corrected to the existing validation contract
before acceptance. The helper tests and registered happy-path doctest were an
additive accepted contract. All accepted hashes stayed unchanged through source
implementation and the source-only Credo helper extraction.

The first full run exposed two annual builder loading regressions and one expected
fixture-count change. Five additional builder tests demonstrated two intended red
failures with three passing guards before independent acceptance and source
correction. The editor fixture count changed from 3,042 to 3,041 because R2-5's
slot 9 Post Call on June 27 is entirely masked by their HNF. The revised test
asserts that exact removal and HNF coverage while preserving the lossless-save
snapshot assertion. The reviewer accepted this expected-behavior revision.

## Runner evidence

- Red: `/tmp/hnf-post-call-red-corrected.log`.
- Original contract green: 11 tests, zero failures,
  `/tmp/hnf-post-call-green-core.log`.
- Final broader focused green: one doctest, 48 tests, zero failures,
  `/tmp/hnf-post-call-green-focused-final.log`.
- Expanded builder red: five tests, two intended failures, three passing guards,
  `/tmp/hnf-post-call-builder-red.log`.
- Expanded focused green: one doctest, 58 tests, zero failures,
  `/tmp/hnf-post-call-expanded-green.log`.
- Owner-scoped `mix format --force` completed before final read-only checks.
- Read-only formatting, compilation with warnings as errors, unused dependency
  check, and strict Credo passed. Final Credo checked 311 files and 2,533
  modules/functions with no issues. Commands: `MIX_ENV=test mix format
  --check-formatted`, `MIX_ENV=test mix compile --warnings-as-errors`,
  `MIX_ENV=test mix deps.unlock --check-unused`, and `MIX_ENV=test mix credo
  --strict`. Logs: `/tmp/hnf-post-call-format-complete.log`,
  `/tmp/hnf-post-call-compile-complete.log`, `/tmp/hnf-post-call-deps.log`,
  `/tmp/hnf-post-call-credo-complete.log`.
- Final full suite: `MIX_ENV=test mix test --seed 298741`, exit 0;
  **215 doctests, 1,669 tests, zero failures**, 45.4 seconds.
  Log: `/tmp/hnf-post-call-full-green-complete.log`. The private-data sentinel
  and profiling tables are intentional test output.
- All five accepted test hashes matched after final source corrections;
  `git diff --check` passed. The runner made no source or test edits.

Authoritative evidence recorded by the workflow runner on October 13, 2026.
Mix/test commands required native sandbox escalation for local sockets and the
test database. Initial full-suite failures remain in
`/tmp/hnf-post-call-full-green.log`; only the `-complete` log represents the final
full green result. Two source-only Credo corrections addressed nesting depth and
alias ordering without changing accepted tests.

Security evidence and remaining pre-existing local OTP advisories are recorded
in [the security review](hnf-post-call-overlap-security-review.md).
