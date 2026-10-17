# Local handoff: finish and merge PR #78

Local continuation on October 16 completed the repository staging gate,
representative persistent fixtures, the profiler race fix, and the real SCP
ownership fix. Live access, configuration import, separate-host staging and
measured recovery/persistence evidence are in
[the local rollout record](phase0-local-rollout-record.md). The final production
owner decision and merge/deployment outcome remain pending; the earlier checklist
below is preserved as the scope and acceptance contract.

Updated October 16, 2026. Continue this work in the local **Residency Scheduler**
project at `/Users/jeffreybaird/src/residency-schedule`, after verifying that path.
The immediate goal is to make
[PR #78](https://github.com/jeffreybaird/residency-schedule/pull/78) ready for its
approved production rollout, merge it, verify the resulting deployment, and
record the outcome. Close it through a successful merge, not by abandoning it.
This handoff itself does not authorize a production deployment.

Work through the remaining tasks below. Continue repository fixes, tests and
operational preparation within existing authorization; do not stop after another
plan or inventory. Ask only for access or decisions that cannot be established
locally, and prepare a concrete release packet before requesting production
go/no-go. Keep separate Phase 0 steps in their own PRs where practical.

## Read first

- `AGENTS.md`, [project guidance](project-guidance.md), and the
  [role-owned workflow](agent-workflow.md). Behavior changes require its accepted
  tests, implementation, runner and independent-review pipeline.
- [Release plan](schedule-adapter-release-plan.md),
  [Phase 0 checklist](schedule-adapter-phase-0.md), and
  [operational baseline](schedule-adapter-phase-0-baseline.md).
- [Release/configuration runbook](phase0-release-artifacts.md),
  [deployment guide](../DEPLOY.md), and [README](../README.md).
- [Managed configuration review](phase0-managed-config-review.md) and
  [verification](phase0-managed-config-verification.md), plus the earlier
  [artifact verification](phase0-release-artifacts-verification.md) and
  [Bandit upgrade evidence](bandit-1.13-upgrade-verification.md).

## Verified starting point

- PR #77 merged the baseline and plans into `main` at `8e44767`.
- PR #78 is open, draft and mergeable on `codex/phase0-release-artifacts`.
  Its latest verified implementation commit is
  `739879f8f286cbf3c4b706910ba2c986ec38257c`; this handoff update follows it.
  [CI run 38914643660](https://github.com/jeffreybaird/residency-schedule/actions/runs/38914643660)
  passed for that implementation. Refresh PR/head/check state before acting.
- Implemented: one immutable code artifact for both destinations; exact artifact
  retention; stable destination locks; migration-before-restart; verified failure
  recovery; private versioned configuration selected with its matching release.
- GitHub Environments `prod` and `demo` are the runtime source of truth. Secrets
  are supplied only to the deploy render step; public settings such as `PHX_HOST`
  use environment variables. Generated host files are private runtime/recovery
  copies. The `.env` path is a compatibility symlink, not a hand-maintained source.
- Tooling is Ruby plus Bash, not Python. The user's Ruby style review comment was
  addressed without adding RuboCop. Preserve that choice.
- Validation passed: 42 deployment tests / 9,695 assertions, 216 doctests and
  1,706 application tests; format, compile, Credo, unused-dependency and syntax
  checks; actual systemd literal parsing; real release archive/privacy checks.
  Tests cover recovery, cookie continuity, optional-setting replacement, target
  guards, unsafe-path rejection and cleanup that preserves recovery/lock state.
- Bandit is **1.13.0**, Thousand Island **1.6.0**. The published Bandit fixes are
  installed and the temporary audit exception is retired; HTTP/2 stays disabled.
  Hex audit was clean on October 16. Ruby-core/RubyGems advisory feeds returned
  HTTP 403, so runtime-wide advisory coverage was not established.

No live deployment, GitHub secret import, host inspection, staging provisioning,
database restore or production migration was performed in the cloud session.
Mocked service tests and the packaging smoke test do not satisfy those gates.

## 1. Resume safely and establish operational access

1. Inspect local changes, worktrees and repository instructions. Preserve existing
   work, fetch origin, inspect PR #78 and its review threads, and continue its
   branch in a clean worktree. Do not replace it with the old baseline branch or
   reset away local changes. Verify whether another operator has advanced the PR.
2. Discover the existing DigitalOcean profile/token binding, SSH agent/config and
   GitHub authentication locally. The owner confirmed tokens exist locally and in
   GitHub secrets; their exact local binding was not verified. Use connection names
   and secret-presence checks, never print tokens or private keys. GitHub secret
   values cannot be read back through the API.
3. Complete the baseline's read-only inventory: deployed source/artifact identity,
   service topology, actual Erlang/Elixir/PostgreSQL versions, applied migrations,
   writers, backup/recovery facilities and current deployment status. Distinguish
   live observations from source assumptions. Store timestamps and sanitized
   findings in the baseline; keep private operational details outside Git.
4. Record the requester as the already confirmed release/recovery/go-no-go owner;
   resolve the available operator, rollout window and retention window. Accepted
   targets are application rollback within **10 minutes**, database recovery
   within **60 minutes**, and at most
   **15 minutes of lost writes**. They remain objectives until measured.

Exit: actual access and deployment state are known, and unknowns are named. Use
local access rather than adding the previously deferred remote inventory workflow
unless evidence shows that workflow is needed.

## 2. Prepare GitHub configuration and target-host prerequisites

1. Use the runbook's schema table as the authoritative inventory. Prepare distinct
   `prod` and `demo` GitHub environments, with appropriate branch restrictions and
   deployment protection. Inspect repository-secret fallback so demo cannot inherit
   production credentials. Do not remove existing secrets until their consumers
   and the replacement path are verified.
2. Privately import the current required runtime values through a secure channel
   or CLI stdin, never through command arguments, chat, logs or committed files.
   Preserve each installation's `SECRET_KEY_BASE` and effective `RELEASE_COOKIE`.
   Cookie continuity is enforced by code; signing-key preservation is an operator
   responsibility. Do not rotate either merely to get the deployment to pass.
3. Set `PHX_HOST`, `CONFIG_ENVIRONMENT` and `EXPECTED_DATABASE_NAME` explicitly for
   each environment. Configure required/conditional secrets and intended optional
   values from the schema; disabled integrations clear old credentials. The URL
   must have no query/fragment; use supported `DB_SSL` configuration deliberately,
   not by silently dropping connection options. Verify actual database grants:
   matching the declared database name does not establish access isolation.
4. Privately inspect systemd units, drop-ins, wrappers and extra EnvironmentFiles
   for competing managed settings. Confirm the effective cookie, not just a file's
   apparent value. Legacy shell `export` or expansion syntax is unsupported; the
   helper never sources `.env`. Prepare an explicit safe transition for unsupported
   legacy forms, retaining the original private recovery state.
5. Verify maintained Ruby 3.3, Bash, `flock`, checksum/tar tools, curl, permitted
   systemd commands, service user ownership, private file/directory modes and disk
   capacity on both hosts. Minitest is development/CI only. Verify release/runtime
   compatibility and the actual systemd EnvironmentFile behavior on the host OS.
   Keep code artifacts, private config versions and the stable lock outside the
   swapped tree; do not prune designated recovery copies.
6. Confirm an existing installed release and usable prior cookie/configuration.
   Promotion does not bootstrap an empty host. Prepare any provisioning or service
   corrections separately, validate them in staging, and include production changes
   in the reviewed rollout packet before applying them.

Exit: both environments have complete configuration, host prerequisites are
verified, and the first-transition recovery/configuration plan is concrete. Secret
presence alone does not prove correct values or a successful deployment.

## 3. Establish persistent staging and a usable rehearsal path

Complete the necessary Step 2 work in its own PR where practical; reference that
dependency from #78. Reuse suitable existing infrastructure if verified. If new
resources or unresolved spending decisions are necessary, first prepare the exact
resource/cost proposal and use the owner's existing authorization where applicable.

Current #78 has only `prod` and `demo` workflow targets, and the configuration
validator accepts only those markers. Simply adding a GitHub environment named
`staging` does not create a working staging destination. Implement and test the
required staging workflow/profile deliberately, with a separate service, database,
credentials, endpoint and Erlang node identity. Keep production destinations
unavailable from branch-only rehearsal runs. Preserve test gates and locking.

Provide a way to build/test the candidate ref and promote its artifact to staging
without first merging into `main`. Establish a staging gate before production
promotion and preserve the same verified artifact bytes across that gate. Record
source SHA and content digest; rebuilding a commit is not proof of identical bytes.

Use persistent synthetic fixtures: multiple years, activities, coverage history,
overnight duty and the April 5–18, 2027 vacation chain. Disable real outbound email,
assistant and telemetry integrations or use isolated test substitutes. Verify
database-role isolation and token/feed separation. Prove persistence across two
deployments. The existing reset-on-deploy demo is not this staging environment;
do not reuse its automatic seed operation for a persistence rehearsal.

If Step 2 depends on #78's tooling, use a stacked branch or other reviewable
dependency arrangement. Any merge to `main`, including a prerequisite PR, triggers
deployment; do not merge a dependency merely to obtain a rehearsal path.

## 4. Rehearse the exact deployment and recovery behavior

Use synthetic staging only, with the real service manager and transport path.
Record commands, exact artifact/configuration identities, sanitized outcomes and
elapsed time. A passing localhost HTTP check alone is insufficient evidence.

- Perform the legacy-to-managed configuration transition. Confirm private
  versions, matching release links, cookie continuity, unchanged signing secret,
  clean transfer inboxes and absence of secrets in archives/logs.
- Deploy a later artifact, change a safe configuration value, disable an optional
  integration, and verify replacement rather than stale inherited settings.
  Retrieve the prior artifact and verify its checksum and associated configuration.
- Cause migration failure in an isolated rehearsal and confirm no active release
  swap/restart. Then cause startup/restart or readiness failure and verify recovery
  of the exact previous code/configuration, cookie and working service. Measure
  application recovery against the 10-minute target. Binary recovery does not undo
  database writes or migrations.
- Attempt two promotions to the same destination and prove the stable lock
  serializes them through migration/restart/recovery. Verify manual maintenance
  uses the same lock and cleanup cannot unlink it or interrupt recovery.
- Reject mismatched target/database settings before transfer, and unsafe archives,
  cookie changes or invalid configuration before active mutation. Inspect failures
  without publishing payloads or raw application/database diagnostics.
- Check running release identity, database readiness, authenticated access and a
  basic LiveView/schedule interaction against synthetic fixtures. Preserve evidence
  that staging data survived both deployments and rollback.

Fix discovered behavior defects through the repository test/review pipeline and
repeat affected checks. If fixes change the artifact or deployment path, rehearse
that final version before relying on earlier results.

## 5. Finish review and prepare the production decision

Update the baseline, staging evidence and #78 description with the actual state.
Refresh review comments and address any new findings. Keep Ruby default-style
conventions without adding RuboCop; use Ruby/Bash rather than Python for tooling.

Before each commit, follow current formatting/check rules and run a fresh security
audit with available advisory data. The old Bandit waiver is historical and grants
no exception. For code changes, obtain the required independent review and green
relevant tests; run the complete checks when the final implementation warrants it.
Do not rerun the whole application suite solely for a documentation edit. Verify
required GitHub checks on the final PR head before recommending merge.

The release packet must name the exact candidate, artifact digest, schema state,
GitHub environment readiness, host prerequisites, staging results, verified prior
code/config recovery target, backup/recovery references, operator, rollout window,
retention decision and abort/recovery steps. State remaining recovery limitations
plainly. If any actual production prerequisite is unresolved, keep the PR draft
and identify the specific blocker and next action.

Once the packet is complete, mark the PR ready for review as appropriate and
present the concrete merge/deployment decision to the owner. Reuse any explicit
approval already given for that exact rollout; otherwise obtain the final go/no-go.
This gate comes from the Phase 0 plan's requirement for separately authorized
production deployment, and merging this PR triggers that deployment.

## 6. Merge, observe, and close out

After the required approval and green checks, merge #78 and follow the resulting
build/staging/production/demo workflow through completion. Verify the actual
running release, expected configuration version and bounded read-only production
health; do not write synthetic records to production. If it fails, execute the
reviewed recovery procedure, verify recovery and report the deployment failure.
Do not treat GitHub's merged status as successful operational completion.

Record the merged commit, workflow links, running artifact/configuration identities,
sanitized verification, any recovery performed and remaining follow-ups. Confirm
PR #78 is merged/closed and the deployment outcome is known.

Finishing #78 does **not** close all of Phase 0. Backup restore/PITR evidence,
comprehensive semantic checks, operator rollback after semantic failure, additive
schema compatibility and disaster recovery remain Steps 4–8 unless independently
completed. Keep their status honest and carry them into separate PRs; do not expand
#78 into the adapter-model migration or claim the 60-minute/15-minute database
objectives are proven by application rollback.
