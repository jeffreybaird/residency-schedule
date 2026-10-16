# Owned eprof cleanup verification

October 16, 2026. This fixes an intermittent existing CI failure in
`LocalRenderProfileTest`: `:eprof.stop/0` can return before the owned profiler
process exits and unregisters. Profiling now retains the exact owned PID,
monitors it before stopping, and waits for its matching `:DOWN` before returning
or propagating a rendering error. An existing borrowed profiler remains untouched.

The workflow test writer added an immediate success → raising callback → success
regression. It monitors the owned PID from the existing rendering hook and requires
the process exit notification to have arrived when profiling returns. Assertions
remain immediate; no sleeps or eventual cleanup assertions hide the race.

The independent reviewer accepted the contract before implementation. Accepted
SHA-256 for `test/residency_schedule_web/local_render_profile_test.exs`:
`4a74524a6b84191709c7054eaad5bc861c796d6d72e3533ea0697e8a2d61feca`.

Authoritative runner evidence:

- Red: `mix test test/residency_schedule_web/local_render_profile_test.exs:96 --seed 0`
  failed at the immediate `assert_received {:DOWN, ...}` assertion: the mailbox
  was empty after profiling returned.
- Green: the entire test file passed, **four tests, zero failures**.
- Green: ten consecutive runs of the focused regression with seed 0 each passed,
  **one test, zero failures** per run.

The source owner ran `mix format --force` before green verification. The accepted
test hash remained unchanged. Independent final review passed without findings:
ownership, exception cleanup, borrowed-profiler preservation and exact PID/ref
matching were checked. Security dependencies were unchanged; the fresh audit
and pre-existing runtime advisory scope are recorded separately in
[staging tooling verification](phase0-staging-tooling-verification.md).
