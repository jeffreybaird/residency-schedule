# November 10 dependency advisory fixes verification

Recorded November 10, 2026. Local validation only; no production deployment,
migration, backfill, service or credentials were accessed.

## Scope and current advisories

Starting source: `main` commit `1b18eabdb1a92cef68949e931cef495d3decb852`.
The starting lock SHA256 was
`52e797eba31a48eee06a6a235a41c40b5b33e277ee7a4edfc1bed6ade8131136`,
identical to the PR #98 audit snapshot. The runner's fresh audit of that exact
lock failed with exit 1 and the following findings; SARIF was retained locally
at `/tmp/pr98ci-audit-baseline.sarif`.

| Dependency | Before → after | Advisory | Affected versions and reported condition |
| --- | --- | --- | --- |
| `ecto` | 3.14.2 → 3.14.3 | EEF-CVE-2026-118391 / CVE-2026-118391 / GHSA-cxjx-vmm2-qr8r | High; `>= 3.4.0 and < 3.14.3`. Unbounded query cache growth from interpolated JSON paths and splice lists. |
| `phoenix_html` | 4.3.0 → 4.4.0 | EEF-CVE-2026-117645 / CVE-2026-117645 | Medium; `>= 1.0.0 and < 3.3.5` or `>= 4.0.0 and < 4.4.0`. Attribute injection through unvalidated attribute names in `attributes_escape/1`. |

Primary Hex package metadata was fetched and read at
`https://hex.pm/api/packages/ecto` and
`https://hex.pm/api/packages/phoenix_html`; upstream changelogs independently
identify these fixed versions. Source searches found no direct application calls
to `json_extract_path`, `splice` or `attributes_escape`; ordinary HEEx rest
attributes exist. This bounds the observed exposure, without proving framework
or indirect paths cannot reach affected behavior.

The dependency upgrade changes only the two compatible lock entries, retaining
`decimal` 3.1.2 and the existing dependency constraints. A separately reviewed
two-test fixture-isolation prerequisite was later cherry-picked as `0af4657`;
the branch therefore includes that shared test fix and the lockfile upgrade.
Neither changes application behavior, migrations or timeouts, and no advisory
suppression was introduced. Final lock SHA256:
`93fb45ce393dc4ce80c96f16e2673b8e5780b1d5600b18237a915f5339db1c1b`.

## Environment and frozen contract

Dependency/build directories are independent copies, not mutable symlinks. The
runner selected `/workspace/.setup/activate.sh` and explicitly used
`MIX_ENV=test MIX_TEST_PARTITION=novadvisoryci` for every Mix/database command.
Both configured database and actual `SELECT current_database()` confirmed
`residency_schedule_testnovadvisoryci` before migrations. Only this new isolated
database was created and migrated; the local development database was not used.

The reviewer accepted the unchanged 240-file tracked-test manifest SHA256:
`07300b7e733d0b3722fd3690dfef2edcf9c3c2cd769687debb5405ad6f756f92`.
The runner checked every entry and regenerated the same manifest before and after
the initial failed run. Its algorithm uses `git ls-files test` order, each existing regular
file represented as `SHA256  repository-relative-path` followed by a newline.

## Validation

The source owner ran `mix format --force mix.lock` before runner checks. All
of these read-only checks passed with exit zero:

```sh
MIX_ENV=test MIX_TEST_PARTITION=novadvisoryci mix format --check-formatted
MIX_ENV=test MIX_TEST_PARTITION=novadvisoryci mix compile --warnings-as-errors
MIX_ENV=test MIX_TEST_PARTITION=novadvisoryci mix credo --strict
MIX_ENV=test MIX_TEST_PARTITION=novadvisoryci mix deps.unlock --check-unused
MIX_ENV=test MIX_TEST_PARTITION=novadvisoryci mix hex.audit
git diff --check
```

Strict Credo checked 378 files with 69 checks and found no issues. The fresh Hex
audit reported “No retired or security advisory packages found.” The lockfile
hash remained unchanged from the final value above.

The genuine unfiltered command ran on this frozen lock and unchanged tests:

```sh
MIX_ENV=test MIX_TEST_PARTITION=novadvisoryci mix test
```

Result: **302 doctests, 1962 tests, seven failures**, 285.8 seconds, seed `255339`,
exit 2. Six failures involved database connection timeouts/cancellation in existing
resident, account, rotation, iCalendar, effective-segment and calendar fixtures or
queries. The existing fixture-isolation regression also timed out waiting for its
synthetic worker's ready message after 15 seconds. The log records sandbox
connections exceeding their existing 15,000ms checkout limit. No timeout was
increased and no assertion was removed. These observations do not establish that
the dependency upgrades caused the failures.

Complete log: `/tmp/novadvisoryci-full.log`. A scoped read-only PostgreSQL activity
snapshot was collected immediately after completion and showed only the diagnostic
connection; it could not establish the earlier blocking chain. The frozen
240-file test manifest and final lock hash remained unchanged after the run.
At this initial stage the unfiltered full suite had not passed on the upgraded
lock; final verification after the shared fixture prerequisite follows.

## Verification after the shared fixture prerequisite

Root cherry-picked only the green two-test fixture fix from PR #98, preserving
the exact upgraded lock. The reviewer accepted the updated 240-file manifest:
`9590e498b9e95361c733f119484b1026f14dfa316244a0298ca133b5e0d958f5`.
The runner regenerated and checked that exact manifest and lock before final
validation. An explicit runtime read confirmed four schedulers and actual
database `residency_schedule_testnovadvisoryci`.

All required read-only checks above were repeated after the prerequisite and
passed, including a fresh Hex audit with no retired or security advisory
packages. Strict Credo again checked 378 files with 69 checks and found no issues.
The runner waited for static checks to finish before the final full command:

```sh
ERL_FLAGS='+S 4:4' MIX_ENV=test MIX_TEST_PARTITION=novadvisoryci mix test --seed 255339
```

Using the original failed ordering, with all tests included, it passed **302
doctests, 1962 tests, zero failures**, 144.4 seconds, seed `255339`, exit zero.
Complete output: `/tmp/novadvisoryci-fixed-full.log`. No source, test or lock edits
and no other Mix jobs overlapped this run. The runner regenerated the final
240-file manifest afterward and confirmed the accepted `9590e498...` hash and
final lock SHA256 were unchanged. The prior failed result remains evidence;
neither timeout increases nor test exclusions were used to obtain green.

Limits: a fresh Hex package audit does not cover OS/runtime/browser/vendored
dependencies. Native source/test hook activation was not verified; role ownership,
accepted hashes and independent review provide recorded workflow evidence.
