# Resident assignment exceptions verification

Authoritative test evidence recorded by the workflow runner on October 13, 2026.
The runner made no source or test edits.

## Red

Before implementation, the focused regression command was:

```sh
MIX_ENV=test mix test test/residency_schedule_web/live/resident_rotation_exceptions_test.exs test/residency_schedule_web/live/resident_specific_rotations_test.exs test/residency_schedule_web/live/daily_assignment_integration_test.exs test/residency_schedule_web/live/qgenda_details_test.exs test/residency_schedule_web/live/friday_night_float_test.exs test/residency_schedule_web/live/preferred_activity_names_test.exs --seed 0
```

Result: exit 2, **10 doctests, 56 tests, 9 failures**. All nine failures were
expected behavior assertions: repeated baseline assignments and empty days/areas
remained visible, and the daily commitments panel remained. Existing task-only
and preferred-name merged schedule assertions passed.

An earlier run had three fixture errors (`detailed_activity_sources.previous_name`
violated a NOT NULL constraint). The spec writer corrected that fixture and
formatted tests; the authoritative rerun above had no fixture or setup errors.
The spec writer also corrected two gap-row selectors that initially used the
wrong existing entry kind. A final red rerun retained all nine expected failures;
the independent reviewer then formally accepted the six-file test contract.

Mix initially failed within the sandbox because its local PubSub TCP socket was
denied (`:eperm`). Native escalation allowed Mix and local PostgreSQL sockets;
the test commands then executed normally.

## Test contract hashes

SHA-256 hashes accepted after final corrected red and before implementation:

```text
770a6b415807abe13d634b9cc8ac8c758093f5a0a32beeaeb750c655a50c0a39  test/residency_schedule_web/live/resident_rotation_exceptions_test.exs
62b87a3055a9c444ffddf7ea5f2190be12418fdc90a46a76c1084ba5cf185d6f  test/residency_schedule_web/live/resident_specific_rotations_test.exs
a6a13b6f2898927fb80fe468ae0b398b731f74db3fc9f08c429eecc9c4c182bc  test/residency_schedule_web/live/daily_assignment_integration_test.exs
24d80bad25f78db3f537666a5d019dc085c3238649c813ffe709ed66f45b62aa  test/residency_schedule_web/live/qgenda_details_test.exs
dc8e2558dbce95fd68bc273ae9b926703ea8a72284d49bb2ef435176459bff9a  test/residency_schedule_web/live/friday_night_float_test.exs
6e817b02059fe0cfca8bada720e6990e1a9745ebcf632e477f21364ea1311279  test/residency_schedule_web/live/preferred_activity_names_test.exs
```

## Green and repository checks

After source-owner implementation and scoped force formatting:

| Command | Result |
| --- | --- |
| Focused six-file command above, `--seed 0` | Exit 0; 10 doctests, 56 tests, 0 failures |
| `MIX_ENV=test mix test --seed 0` | Exit 0; 215 doctests, 1673 tests, 0 failures; 66.7 seconds |
| `MIX_ENV=test mix compile --warnings-as-errors` | Exit 0 |
| `MIX_ENV=test mix format --check-formatted` | Exit 0 |
| `MIX_ENV=test mix deps.unlock --check-unused` | Exit 0 |
| `MIX_ENV=test mix credo --strict` | Initial exit 4; alphabetical alias-order issue in new test, routed to spec writer |
| `mix assets.build` | Exit 0; Tailwind and esbuild completed |

All six accepted test hashes matched after these checks. The lint-only correction
requires independent review, refreshed hash, and relevant verification below.

The full suite emitted existing negative `Date.range/2` warnings from
`test/support/schedule_gaps_reference.ex` and compile-time `:eprof` availability
warnings from `local_render_profile_test.exs`. Its profiler tests nevertheless
executed and passed; these warnings did not affect the successful suite result.

### Lint correction verification

The spec writer reordered aliases only and force-formatted the new test. The
independent reviewer accepted this correction: reversing the alias reorder
reproduced the original accepted hash exactly, preserving all assertions.

Renewed accepted SHA-256 for `resident_rotation_exceptions_test.exs`:
`6321d87c7aa40a69345cd25577775a974848d9bbfa79bbe0c904e17ec4ce320c`.
The other five accepted hashes remained unchanged. All six matched after final
verification.

| Command | Result |
| --- | --- |
| `MIX_ENV=test mix test test/residency_schedule_web/live/resident_rotation_exceptions_test.exs --seed 0` | Exit 0; 4 tests, 0 failures |
| `MIX_ENV=test mix format --check-formatted` | Exit 0 |
| `MIX_ENV=test mix credo --strict` | Exit 0; 312 files checked, no issues |
| `git diff --check` | Exit 0 |

The complete suite was not repeated after the reviewed alias-only correction;
its earlier green result covers the unchanged behavior and source.

## Security review

Independent reviewer checks on October 13, 2026:

- `mix hex.audit`: exit 0, no retired or security advisory packages. Initial
  sandbox execution failed on the Mix PubSub socket (`:eperm`); native escalation
  succeeded. Hex warned that authentication expired and continued anonymously;
  private resources were unavailable.
- Retrieved the current [public Hex OSV database](https://osv-vulnerabilities.storage.googleapis.com/Hex/all.zip).
  Its 377 records are byte-identical to the previously evaluated explicit-version
  and semantic-range scan; all 51 locked package/version pairs are also identical.
  That scan has zero matching advisories and zero unsupported applicable ranges.
  Decimal remains patched at 3.1.2. Fresh evidence:
  `/tmp/resident-exceptions-hex.zip`; compared scan:
  `/tmp/render-diagnostics-hex-result.json`.
- Retrieved the [official OTP advisory API](https://api.github.com/repos/erlang/otp/security-advisories?per_page=100).
  All 70 records are unchanged. `elixir -e` runtime/component inspection confirms
  OTP 29.0.1 / ERTS 17.0.1, ssl 11.7.1, ssh 6.0, inets 9.7, snmp 5.20.4,
  eldap 1.3, asn1 5.5, public_key 1.21.1, megaco 4.9, stdlib 8.0,
  erl_interface 5.8 and ftp 1.2.5, matching the prior review. Fresh evidence:
  `/tmp/resident-exceptions-otp.json`.

The **40 pre-existing local OTP advisories remain**. Their individual identifiers,
affected and installed versions, patched component versions and exposure
conditions are recorded in the [runtime advisory table](qgenda-oct12-security-review.md#pre-existing-host-runtime-findings),
verified against the fresh unchanged official records. Complete patched OTP
options are **29.1.1, 28.5.0.7 or 27.3.4.18**. Repository tooling, CI and deployment
already pin 28.5.0.7; the shared host executable remains unchanged. Actual
production runtime is unverified. Outgoing TLS can reach affected SSL/public-key/
ASN.1 components; precise exploit prerequisites and production exposure remain
uncertain. App SSH/SFTP, SNMP, LDAP, Megaco and FTP use was not observed.

No compatible locked-dependency security upgrade is outstanding. Vendored/Git
assets, operating-system packages, undisclosed issues and actual production
runtime are outside this Hex comparison; this is not a comprehensive clean scan.

Independent implementation review confirms filtering uses the existing exact
task-equivalence map, preserves meaningful notes and unknown tasks, and stays
within the selected resident appearance and rotation date range. Notes continue
through escaped HEEx rendering. Calendar behavior and coworker queries are
unchanged. The removed panel's event, assigns and unused helper were removed.

Audit review found an ambiguous runner-role warning during a read-only Mix help
command overlapping the spec writer's five test migrations. The recorded diffs
match the writer's owned changes; no unauthorized runner edit is evidenced.
The six accepted test hashes were unchanged through implementation and full
green. The later alias-order correction was independently verified to change
only the order of two aliases; its refreshed hash is recorded above.
