# Nonempty all-day calendar events before night duty

Recorded October 28, 2026. This is the isolated legacy-defect prerequisite
identified by PR #96 in the [effective-read verification](schedule-effective-read-verification.md).
Baseline: `12e5bc805372ec1d77a2dd02a8467fe2f386d94a`.

A one-day all-day segment immediately before an unsourced night block previously
had identical DTSTART and exclusive DTEND. The calendar builder now skips the
last-day trim when it would empty the event. Its UID stays unchanged. Multi-day
trimming and sourced-night boundaries retain their existing behavior.

## Accepted contract

The spec writer added structured-event and feed regressions covering all five
all-day types, the two-day trim boundary, and sourced-night behavior. The existing
Highland acceptance scenario now requires the one-day post-call event to end the
following day. The reviewer accepted this intentional correction to the prior
contract before source implementation.

| Test | SHA256 |
| --- | --- |
| `test/residency_schedule/ical_events_test.exs` | `85549e1ac6224f523389f4b2db1fa24cfa8412f86b9966e4be79a6424d15621a` |
| `test/residency_schedule/effective_schedule/acceptance_test.exs` | `71d828188af6ac5d3014b6990bb0dca5703ce062ce2e3d721583d40eef7910bb` |

The runner executed `mix test test/residency_schedule/ical_events_test.exs
test/residency_schedule/effective_schedule/acceptance_test.exs` before implementation:
15 doctests, 36 tests, 2 expected failures, seed 444868. Both failures required
DTEND `20261108` and observed `20261107`. After the source change the same command
passed: 15 doctests, 36 tests, zero failures, seed 379527. Accepted hashes match.
Source and test owners ran `mix format --force` on their respective paths.

## Environment and review

Local Elixir 1.19.5 / OTP 29; local test database only. Sandbox socket restrictions
required elevated commands. `mix deps.get` synchronized existing locked Bandit
1.14.1 and plug_crypto 2.2.1; `mix.lock` SHA256 stayed
`52e797eba31a48eee06a6a235a41c40b5b33e277ee7a4edfc1bed6ade8131136`.

The independent reviewer found no implementation or test-contract issue.
`mix hex.audit` passed with no retired or security-advisory packages. An initial
Hex cache warning did not recur on the repeat audit. This is a Hex-package audit,
not an operating-system or comprehensive CVE scan. Production exposure was not
inspected. The audit log contains historical violations; no new entries appeared
for this task, so runtime hook activation is unverified. Role ownership was
maintained explicitly and reviewed against the final diff.

No migrations, data changes, production commands, deployment, or consumer routing
changes were made. Comparison remains on the legacy adapter for both versions.

## Final verification

Runner verification after the owned-path format corrections:

- Full `mix test`: 302 doctests, 1962 tests, zero failures, seed 902347,
  62.7 seconds.
- `mix format --check-formatted`, `MIX_ENV=test mix compile --warnings-as-errors`,
  and `mix deps.unlock --check-unused`: exit zero.
- `mix credo --strict`: 378 source files, 3045 modules/functions, no issues.
- Accepted test hashes remained unchanged.

The full suite emitted existing negative-range date warnings and profiler output;
neither produced a test failure. No new advisory or final-diff findings remained.
