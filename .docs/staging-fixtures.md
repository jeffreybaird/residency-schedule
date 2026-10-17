# Manual persistent staging fixtures

The manual `ResidencySchedule.Release.seed_staging/0` entry point requires
`CONFIG_ENVIRONMENT=staging`, an affirmative `EXPECTED_DATABASE_NAME` declaration
of `residency_schedule_staging`, and a query proving the connected database has
that exact name. It refuses other declarations or connections before fixture writes.
The fixture context itself is a database context, not an authorization boundary;
operators use the guarded release entry point.

Run this once after an installed staging release has migrated successfully. Do
not add it to deployment jobs. Later deployments must preserve its records.
Load the private managed EnvironmentFile through systemd, never shell `source`,
and hold the same stable destination lock used by promotion. For an operator
with appropriate systemd privileges, the sanitized command is:

```bash
INSTALL_DIR=/home/deploy/residency_schedule_staging
test -f "${INSTALL_DIR}.deploy.lock"
sudo flock -x "${INSTALL_DIR}.deploy.lock" \
  systemd-run --wait --pipe --collect --uid=deploy \
  --property="WorkingDirectory=${INSTALL_DIR}" \
  --property="EnvironmentFile=${INSTALL_DIR}/.env" \
  --setenv=EXPECTED_DATABASE_NAME=residency_schedule_staging \
  "${INSTALL_DIR}/bin/residency_schedule" eval \
  'case ResidencySchedule.Release.seed_staging() do {:ok, _} -> IO.puts("Synthetic staging fixtures ready"); _ -> raise "Staging fixture import rejected" end'
```

Use this only on the verified isolated staging host. The `.env` path must already
be the private managed symlink paired with the installed release. Do not print
the file or include its contents in commands or evidence. This command records
only public paths, a public database marker and a fixed success/rejection message.
The explicit expected database marker is intentional: normal service configuration
does not export that metadata marker. Actual database identity is checked as well.

The fixture covers academic years 2025, 2026 and 2027 with shared synthetic
resident identities and independently generated feed tokens. It includes historic
coverage, concurrent clinic/rotation tasks, overnight duty, and the April 5–18,
2027 vacation chain: weekday roster blocks joined by imported weekend vacation
activities with provenance. Repeating the seed preserves IDs, feed tokens and
manual records; conflicting fixture identity or fields abort the transaction.

The synthetic `staging-admin@example.test` account is approved as an administrator
without a seeded password or magic-link token. Set a random password privately
through the existing Accounts context for an authenticated smoke test. Never
commit or publish it. Reruns preserve operator-set credentials and active tokens;
an existing conflicting account is rejected rather than silently elevated.

Synthetic accounts and feed tokens belong only to staging. Their presence is not
proof of database-role isolation, deployment persistence or successful recovery.
Record those operational checks separately.

## Repository verification

The role-owned workflow accepted the representative fixture contract before its
implementation. Initial red evidence was the missing fixture module; renewed
tests then failed for the absent admin, incorrect weekly vacation blocks and
missing concurrent activities. A later projection failure exposed missing source
provenance, which was corrected in fixture data without weakening assertions.

Final accepted SHA-256 for `test/residency_schedule/staging_fixtures_test.exs`:
`8d9176d89bd69f5a43f9edeb461c78d5048c00361bfebb82e61a96412ee84946`.
Formatting and alias corrections preserve the contract and receive renewed
independent review. The runner confirmed the final hash matches the reviewed
snapshot.

Authoritative green on October 16, 2026:
`mix test test/residency_schedule/staging_fixtures_test.exs test/residency_schedule/release_test.exs`,
seed 598173: **five doctests and 13 tests, zero failures**. Read-only format checks
passed after source/test owners formatted their files. Fixture doctests execute
through the test module's `doctest` registration; database behavior has actual
Sandbox integration coverage.

Independent final review passed. It checked atomic conflicts, preservation of
manual records and credentials, real database guard composition, provenance and
public effective schedule semantics. The exact dedicated-database entry-point
success still requires live isolated staging evidence. Dependencies did not change;
current audit scope and pre-existing findings remain in
[staging tooling verification](phase0-staging-tooling-verification.md) and the
operational rollout record.

Final stable-source broad checks also passed after the owners corrected strict
Credo style findings and formatted their respective paths:

- `mix format --check-formatted`
- `MIX_ENV=test mix compile --warnings-as-errors`
- `mix credo --strict` — 320 files, 2,605 modules/functions, no issues
- `mix deps.unlock --check-unused`
- `mix test` — seed 431912, **217 doctests, 1,722 tests, zero failures**
- Linux deployment suite — seed 54791, **47 tests, 10,638 assertions, zero failures**
- Fresh `mix hex.audit` — no retired or advisory packages reported
- `git diff --check` and all accepted test hash comparisons
