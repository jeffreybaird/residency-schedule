# Ambulatory/weekend transition independent review

## Accepted test contract

Before implementation, the independent reviewer inspected the final synthetic fixtures and outcome assertions and accepted the following bytes after the runner's authoritative red evidence: `/tmp/ambulatory-night-transition-contract-red.log`, 1 doctest, 21 tests, 15 behavioral assertion failures and no fixture/predicate exceptions (exit 2).

```text
14721457856bbbfe321b1ff9ab02eb1f413801c21754410ecd5a60bd588ffe47  test/residency_schedule/strong_night_projection_test.exs
fe5475a9ceb590999ed968089f56830ba1f78954842a3ab77952d4d6da0e7c48  test/residency_schedule_web/live/friday_night_float_test.exs
```

## Final independent acceptance

The reviewer independently inspected the final normalizer, projection integration, Friday detailed-duty classification, ICS timing and cache-version change. Canonical adjacent candidates are grouped so unrelated overlapping rotations cannot hide a pair. Explicit Friday preservation is restricted to canonical NF; unrelated post-call work remains intact and existing post-call spans prevent synthetic duplication. Approved overrides restore their original source identity/type on their actual dates. Derived markers survive later projection and anchor every exported night in the evening; raw editing/import APIs retain stored dates. Version 3 prevents warmed version-2 grids from serving stale dates without requiring reimport or database writes.

The runner's final focused evidence is `/tmp/ambulatory-night-transition-final-focused-green.log`: 2 doctests, 35 tests, zero failures. The final full-suite evidence is `/tmp/ambulatory-night-transition-final-full-green.log`: 216 doctests, 1,682 tests, zero failures in 65.4 seconds. Formatting, warnings-as-errors compilation, unused dependencies, strict Credo and diff checks passed; strict Credo inspected 313 files / 2,557 modules and functions with no issues. The reviewer rechecked the final hashes listed under “Accepted review refinements” after implementation; all are unchanged.

The current Hex advisory scan is clean within its documented scope; independent OSV/OTP feeds remain blocked and actual production runtime is unverified. The Bash audit remains at its pre-existing 280 entries / 98 ambiguous violation flags, with no exclusive flags and no new task entries. Live cloud audit activation therefore remains unverified; role communications, preserved test hashes and final diff inspection are the available ownership evidence. No unowned source/test edit or unresolved actionable implementation defect was established. Final implementation accepted.

The contract covers the November 2–19 example without reimport: paired Mon–Fri ambulatory and Sat–Sun Strong Weekend Nights become Mon–Thu ambulatory and Fri–Sat night starts; canonical Mon–Fri Night Float becomes Sun–Thu night starts. Paired post-call spans follow the corrected nights. Raw dates and edit identities remain unchanged. Already aligned, noncanonical and other-site spans retain their behavior. Approved overrides retain their actual dates, source types and participant identities. Calendar, resident display, effective queries and evening-to-morning ICS exports share the correction.

The earlier Friday detailed-contact-night expectation is intentionally revised from Night Float to Strong Weekend Nights to follow the user's clarified duty. Its filtering, coverage, literal source evidence and export deduplication protections remain asserted. The fixture correction before acceptance supplied the required real synthetic import batch/activity source; the coverage predicates received explicit nil guards and consistent boolean operators. Neither correction weakens the expected behavior.

Security evidence and audit limitations are recorded in [the security review](ambulatory-weekend-transition-security-review.md).

## Accepted review refinements

The reviewer identified that a single-value endpoint index could hide a canonical Ambulatory/weekend pair when unrelated rotations shared a start or end date. The implementer separately identified overly broad removal of unrelated post-call days and duplicate synthetic Friday post-call work. The writer added outcome regressions for all three; no original expected assertion changed. The writer also registered the new module's doctest.

A warm-cache regression seeds the old version-2 key at the exact current repository/revision/date and requires the corrected projection without a database write, followed by reuse of the corrected cache. The runner demonstrated all four expected failures before the corresponding source corrections: `/tmp/ambulatory-night-transition-refinement-contract-red.log`, 1 doctest, 22 tests, 4 behavioral assertion failures, exit 2. The reviewer accepted these updated contracts:

```text
25dad6c20617521076fae041955fe876c020b4347f55853dd47b7d94c9c1b5c9  test/residency_schedule/strong_night_projection_test.exs
764f2e627fe98bba8482370748d84760bb5826380aaaf35a8e2f0616e4173dd7  test/residency_schedule/schedule_cache_integration_test.exs
fe5475a9ceb590999ed968089f56830ba1f78954842a3ab77952d4d6da0e7c48  test/residency_schedule_web/live/friday_night_float_test.exs
```
