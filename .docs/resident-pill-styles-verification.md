# Resident rotation pill styling — issue #59

Original and imported rotation labels on resident timelines use the same pill
layout: centered text, a shared maximum width, padding, and minimum height.
Long labels wrap without truncation. Rotation colors, specific imported labels,
notes below the pill, and coverage indicators remain intact.

## Verification

Authoritative runner evidence; no source/test edits by the runner. Local runtime
is Elixir 1.19.5 / OTP 29.0.1. Mix required native escalation for local sockets and
the test database. Owners formatted source/tests before read-only checks.

Red command:

```sh
MIX_ENV=test mix test test/residency_schedule_web/live/resident_specific_rotations_test.exs --seed 0
```

Exit 2: **7 doctests, 16 tests, 2 expected failures**, 1.2 seconds. Imported/base
class sets differed in the Vacation and Ambulatory R4 cases.
Log: `/tmp/resident-pill-red.log`.

Focused green command:

```sh
MIX_ENV=test mix test test/residency_schedule_web/live/{resident_specific_rotations,resident_imported_schedule,resident_live}_test.exs --seed 0
```

- Focused: exit 0; **10 doctests, 58 tests, 0 failures**, 10.6 seconds.
  Log: `/tmp/resident-pill-focused-green.log`.
- `MIX_ENV=test mix format --check-formatted`: exit 0.
- `MIX_ENV=test mix compile --warnings-as-errors`: exit 0.
- `MIX_ENV=test mix deps.unlock --check-unused`: exit 0.
- `MIX_ENV=test mix credo --strict`: exit 0; 275 files, 2,249 modules/functions,
  no issues. Log: `/tmp/resident-pill-checks.log`.
- `MIX_ENV=test mix assets.build`: exit 0; Tailwind and esbuild completed.
  Log: `/tmp/resident-pill-assets.log`.
- `MIX_ENV=test mix test --seed 298741`: exit 0; **205 doctests, 1,553 tests,
  0 failures**, 52.8 seconds. Log: `/tmp/resident-pill-full-green.log`.
  The private-data sentinel is intentional test output.
- Accepted test hash below remained unchanged after final execution.
- `git diff --check`: exit 0.

No JavaScript source changed; unrelated JavaScript tests were not repeated.

## Security

Review the change against the existing
[October 12 security report](qgenda-oct12-security-review.md), retaining its local
runtime findings and production-verification limitations.
## Independent review

The reviewer accepted the frozen test contract after the runner recorded two
expected class-set failures. Its Vacation and Ambulatory R4 cases compare actual
imported and base pills, require the same bounded centered wrapping styles, and
preserve notes outside the pill. Existing coverage and long-label tests remain.

The complete source diff replaces one conditional class branch with one shared
class set on the main resident timeline's label span. Width remains bounded at
11rem, height can grow for wrapping, and horizontal and vertical alignment is
centered. Color, covered-state classes, titles, task labels, and notes are
unchanged. No other view's styling changes. Final acceptance follows the runner's
passing 205 doctests and 1,553 tests, required static checks, and asset build.
The accepted test hash remains unchanged. No implementation blockers remain.

Accepted test SHA-256:
`ecc84c8fc0203b5493c502787d18311fc0689d5e8bf9dc8838dae9c91f099c92`.
The new audit entry is an owner-scoped writer formatter with no violations.

Dependency manifests and lockfile are unchanged. Same-session October 12
security evidence remains applicable: Decimal 3.1.2 fixes GHSA-6c27-994x-c52f /
CVE-2026-97853 (affected below 3.1.2), and the post-upgrade OSV scan found no
matches among 51 locked Hex packages. The active local OTP 29.0.1 runtime retains
the 40 pre-existing advisories documented individually in
[the security report](qgenda-oct12-security-review.md), including component
versions and exposure conditions. Patched release options are 29.1.1, 28.5.0.7,
or 27.3.4.18. Repository pins specify 28.5.0.7; actual production runtime and
endpoint-specific exposure remain unverified. These host findings remain open.
