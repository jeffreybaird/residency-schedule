# PR #103 merge verification

Recorded November 10, 2026. This validates the automatic merge of advisory branch
head `29e5508cad3604be397f4372b7dbd5a41f632ff0` with current `main`
`d3eede5b9c4ae00c3c4e320c0da64119fdb436c9` after PR #102.
Runtime/source, configuration and assets match current main. The dependency
change remains exactly two fixed lock entries: Ecto 3.14.2 → 3.14.3 and
Phoenix.HTML 4.3.0 → 4.4.0. Subsequent CI reliability work intentionally changes
the shared test templates and adds a behavioral scheduling probe, described
below; the final branch is no longer an all-tests-unchanged merge.

The unchanged fixed lock SHA256 is
`93fb45ce393dc4ce80c96f16e2673b8e5780b1d5600b18237a915f5339db1c1b`.
Before harness work, the reviewer accepted the then-current 247-file manifest SHA256
`e441b91297b012fe6c6025cf8963ec68b7a5fd4b06b9c7c7b2480ddd0a72a786`;
the runner independently regenerated and checked it before validation.

Existing independent dependency/build directories were retained with the fixed
versions. All Mix/database commands explicitly selected
`MIX_ENV=test MIX_TEST_PARTITION=pr103merge` under
`/workspace/.setup/activate.sh`. Configuration and actual `SELECT current_database()`
confirmed `residency_schedule_testpr103merge` before the new isolated database
was migrated. No development/production database, deployment, backfill or
consumer switch was used.

Initial read-only formatting, warnings-as-errors compilation, strict Credo (394 files,
69 checks, no issues), unused-lock and whitespace checks passed. A fresh
`mix hex.audit` exited zero: “No retired or security advisory packages found.”
This clears the previously recorded EEF-CVE-2026-118391 and EEF-CVE-2026-117645
findings on the fixed versions; their identifiers, affected ranges, exposure
limits and the prior failed run remain in the historical
[advisory verification](november-10-advisory-fixes-verification.md).

Before harness work, this unfiltered whole-suite command ran on frozen
source, tests and lock:

```sh
MIX_ENV=test MIX_TEST_PARTITION=pr103merge mix test --max-cases 1
```

Result: **314 doctests, 2021 tests, zero failures**, 161.3 seconds, seed `487004`,
exit zero. The accepted 247-file manifest and fixed lock SHA256 were unchanged
afterward; runtime/test/config/assets then matched current main. Complete
output: `/tmp/pr103merge-serial-full.log`. Serial execution retained all
tests, internal test concurrency and existing timeout values; it does not prove
default parallel execution is green. No source/test/lock edits or other Mix jobs
overlapped this run.

The normal CI reliability issue prompted the harness work below. At the same
original advisory head `29e5508`, the
[pull-request job passed](https://github.com/jeffreybaird/residency-schedule/actions/runs/42843064953/job/129923121493),
while the [push job failed](https://github.com/jeffreybaird/residency-schedule/actions/runs/42842719303/job/129921892153)
in `mix test`, with annotations naming ShiftOverrides/iCalendarOverrides tests.
Raw CI failure stacks were unavailable; these outcomes do not establish a
dependency logic regression.
The serial local pass is diagnostic coverage, not resolution of that blocker.
The merge/commit gate was paused for a bounded test-harness investigation.

## Normal CI scheduling regression

The reviewer accepted a behavioral scheduler probe before changing the shared
test templates. Frozen wrapper SHA256:
`c216ad9710da43256866e9e7e7959529bcdb8f9b95d98f84dc6a9dee0aaee81a`;
probe helper SHA256:
`48a30b24b985053fc5e0e581ae1091de57695b62f7db615b97e320a7d1daf337`.
The runner verified both before and after the red run and confirmed the existing
DataCase/ConnCase templates still matched main. After actual database readback:

```sh
MIX_ENV=test MIX_TEST_PARTITION=pr103merge mix test test/residency_schedule/fixture_group_scheduling_test.exs
```

Result: **one test, one expected failure**, 6.8 seconds, seed `140401`, exit 2.
The child used real DataCase/ConnCase templates and an independent ExUnit module,
with `mix test --no-compile`, seed zero, `--max-cases 2`, explicit test environment
and the same isolated partition. It ran **three tests, one failure** in 5.1 seconds:
the DataCase fixture's five-second overlap barrier reported
`:independent_module_could_not_overlap_shared_fixtures`. Both other child tests
passed. No database setup, configuration or compilation error supplied red.
The template fix was released only after this result; no business assertion or
timeout was weakened. Complete local output: `/tmp/pr103-group-red.log`.

The writer added the same default ExUnit resource group in DataCase and ConnCase,
preserving `async: true`, Sandbox ownership, explicit group overrides and
concurrency inside tests. A focused probe/ShiftOverrides/iCalendarOverrides/
ImportPreview/Toolbox run passed **four doctests, 34 tests, zero failures**,
3.7 seconds, seed `888189`, exit zero. The child protocol's seed zero and
`--max-cases 2` belong only to the regression probe, not global CI settings.
Initial strict Credo then rejected the support probe filename; that fixture
packaging correction was returned to the test writer before a full run.

The writer renamed the support fixture to `shared_fixture_group_probe_test.exs`
and guarded all child modules/controller behind the private child-process marker
`RESIDENCY_FIXTURE_GROUP_PROBE=1`. The wrapper alone sets that marker for its
child. The reviewer accepted renewed wrapper/helper hashes
`943047a9922fd29fb106587ba9853d0d4ae83b6a37dc7c73490ac728370c7d8c`
and `3c2ffe9470353e0ec2a464a6fec03db7ae22fd12318335a902ca375ae55f41c3`.
DataCase and ConnCase hashes remained respectively
`c68b2d8ed034bcd9b671d72f61f60dd6f5743620f4e946a580fca8e47661686d`
and `c0657ac13724c15b18f9dd640249c7c832c7286284ed0bbcfa9d3c3c302130ff`.
The full staged 249-file contract was regenerated and verified at manifest SHA256
`746ffdf4e1a67b971bdc2f5de64d90aaf95f4e131724ff7d1b41f7a7614bdb6b`.

The final focused run explicitly selected both the helper and wrapper with the
parent marker unset, plus the four earlier CI-failing test modules. It passed
**four doctests, 34 tests, zero failures**, 3.0 seconds, seed `494310`, exit zero.
The unchanged parent count confirms the helper adds no parent probe cases, while
the wrapper still requires its three child cases to pass. All final read-only
checks passed: format, warnings-as-errors compile, strict Credo (396 files,
69 checks, no issues), unused-lock, fresh clean Hex audit and whitespace.

The final unfiltered default-parallel command used the known previously failing
seed and no worker-count override:

```sh
env -u RESIDENCY_FIXTURE_GROUP_PROBE MIX_ENV=test MIX_TEST_PARTITION=pr103merge mix test --seed 255339
```

Result: **314 doctests, 2022 tests, zero failures**, 127.5 seconds, seed `255339`,
exit zero. ExUnit explicitly reported its normal `max_cases: 8`. The extra single
outer regression test explains the count increase; guarded helper cases run
only in its child. Complete output: `/tmp/pr103-group-default-full.log`.
The private child marker was unset for the parent run. No independent validation
Mix jobs overlapped it; the intentional regression child remained part of the
suite. All four accepted harness-file hashes, the 249-file contract and fixed
lock hash were unchanged after the run. Runtime/config/assets still match main.
No timeout, application behavior or business assertion was changed, and normal
CI worker counts were not reduced. Fresh external CI remains a separate result.

The earlier security verification is historical evidence, not fresh validation
of current main. Native hook activation remains unverified; accepted hashes,
role ownership and independent review provide workflow evidence. Hex auditing
does not cover OS/runtime/browser/vendored dependencies.
