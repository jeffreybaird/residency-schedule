# Operation tracing verification

## Accepted contract and red evidence

The workflow spec writer owns test changes; the implementer owns source changes.
The reviewer accepted the bounded operation-tracing contract before source work.
The runner recorded these failing checks before implementation:

```
MIX_ENV=test mix test test/residency_schedule_web/operation_tracing_test.exs test/residency_schedule/observability_transport_test.exs --seed 0
```

Result: 12 tests, 12 expected failures for missing tracing APIs and exported
operation spans. Local evidence: `/tmp/operation-traces-red.log`.

The final test set added executed doctest registration:

```
MIX_ENV=test mix test test/residency_schedule_web/operation_tracing_test.exs test/residency_schedule/observability_transport_test.exs test/residency_schedule/observability_doctest_test.exs --seed 0
```

Result: expected compilation failure because the new `Tracing` module did not
exist yet. Local evidence: `/tmp/operation-traces-red-final.log`.

Accepted SHA-256 hashes:

| Test file | SHA-256 |
| --- | --- |
| `test/residency_schedule_web/operation_tracing_test.exs` | `00be7b7a7c6f957a6b19ad106f3a82c4d731a050ab9dd9e2962468add6a9283a` |
| `test/residency_schedule/observability_transport_test.exs` | `1b6f691f00aeddce6c801f1bdbedb104aace192a440be4d6163fdc040af44f66` |
| `test/residency_schedule/observability_doctest_test.exs` | `17006697484b5a501aff474418df0205e245474bcca38973b1b07c2370b79498` |

The operation test initially had hash
`3d82bc33ef74230a8b1aba1f85a4844574c76ffada2840f4a4517c08cff8b2d8`
at the final red run. The reviewer subsequently accepted one stronger assertion
requiring an empty exported exception-status message; no expectation was relaxed.
The runner repeated red at that accepted hash (`993893cb...`), recorded in
`/tmp/operation-traces-red-accepted.log`. A subsequent reviewer-accepted
regression enforces an exact attribute-key allowlist and empty events/links for
every decoded span (`654684a6...`). Strict Credo then requested a `Sandbox`
alias; the spec writer corrected only the alias, and the reviewer verified
unchanged assertions and accepted the final hash in the table.

The tests exercise decoded OTLP exports from a fake HTTP collector, real seeded
calendar and schedule LiveViews, static and connected callbacks, separate
render roots, true parallel Ecto preload workers, inclusive numeric counters,
context restoration, error cleanup, privacy exclusions, span budgets, malformed
telemetry, and disabled behavior. Nontransactional test fixtures have cleanup
paths for both success and failure.

Security review is recorded in
[operation-tracing-security-review.md](operation-tracing-security-review.md).

## Green verification

The runner's full suite passed with seed `238741`: **210 doctests, 1,575 tests,
zero failures**, in 54.8 seconds. Evidence:
`/tmp/operation-traces-green-full.log`. The browser latency tests passed:
**10 tests, zero failures**, `/tmp/operation-traces-green-browser.log`.

Compilation with warnings treated as errors, read-only formatting verification,
and unused-dependency verification passed. Initial strict Credo found four
nested-module alias suggestions. Source and test owners applied those fixes
and force-formatted their respective files; the reviewer accepted the
nonbehavioral corrections before the runner repeated relevant checks.

After those corrections, the runner verified the accepted hashes and recorded
**11 doctests, 35 focused tests, zero failures**. Compilation with
`--warnings-as-errors`, `mix format --check-formatted`, and `mix credo --strict`
all passed. Credo checked 281 files and 2,322 modules/functions with no issues.
Final evidence: `/tmp/operation-traces-green-focused-final.log`,
`/tmp/operation-traces-green-compile-final.log`,
`/tmp/operation-traces-green-format-final.log`, and
`/tmp/operation-traces-green-credo-final.log`. The unused-dependency check passed
in `/tmp/operation-traces-green-deps.log`; the alias-only corrections changed
no dependencies. No required checks remain outstanding.

Independent review found no correctness or privacy blockers. Review covered
endpoint exception cleanup and early returns, phase boundaries, fixed attribute
allowlists, shared preload counters, disabled operation, context restoration,
bounded span budgets, and the final public API integration-test exemptions.
Audit review distinguished the pre-existing ambiguous `git pull`/overlapping
command entries from current role-owned edits; current spec-writer and
implementer changes have no role violations. No deployment or push occurred.
