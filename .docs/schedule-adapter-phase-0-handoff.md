# Phase 0 local continuation

Recorded October 15, 2026. Continue the existing Phase 0 effort, keeping each
step in its own PR where practical. Start with the
[release plan](schedule-adapter-release-plan.md),
[Phase 0 checklist](schedule-adapter-phase-0.md) and
[baseline](schedule-adapter-phase-0-baseline.md).

## Saved work

- [PR #77](https://github.com/jeffreybaird/residency-schedule/pull/77),
  `codex/phase0-baseline`: plans, repository inventory, accepted owner/targets and
  this handoff. Operational Step 1 evidence is still incomplete.
- [Draft PR #78](https://github.com/jeffreybaird/residency-schedule/pull/78),
  `codex/phase0-release-artifacts`, commit
  `64ba9bf3b7a8fcd818dd4825e8df0092cc5a57af`: Step 3 implementation. Build once,
  retain secret-free artifacts identified by commit plus content digest, serialize
  host promotion/recovery and verify recovery health. Runtime configuration and
  cookies remain private. See its operator runbook, verification and review under
  `.docs/phase0-release-artifacts*.md`.
- Step 3 validation: 18 deployment tests, 216 doctests and 1,706 application tests
  pass. Static checks and actual Mix release packaging and temporary-directory
  staging pass. These do not demonstrate live-host or persistent-staging readiness.
- Both branches start from reviewed main
  `79e35115db5149746b5e47d0f6345542e755c361`. Refresh Git and PR state before work;
  do not assume either PR is still open or already merged.

No production deployment, migration, restore, service stop or staging provisioning
was performed. Merging into main triggers deployment, so keep PR #78 in draft
until its host prerequisites and staging rehearsal have been verified.

## Resume locally

The desktop app lists the local **Residency Scheduler** project at
`/Users/jeffreybaird/src/residency-schedule`. The cloud session could identify the
project but had no callable transfer action; this record does not mean a transfer
has occurred. Open or continue work in that local project through the app.

1. Read repository instructions, inspect local changes and worktrees, fetch origin
   and inspect both PRs. Preserve existing changes; use isolated worktrees for
   separate steps. This documentation is on `codex/phase0-baseline` until merged.
2. Inspect existing DigitalOcean CLI/profile and SSH connection configuration
   without displaying credential values. The requester confirms credentials exist
   locally and in GitHub repository secrets. Their exact local binding has not
   been verified. GitHub secret values cannot be read back through the API.
3. Complete the baseline's read-only inventory: deployed SHA, selected service
   properties, PostgreSQL/runtime and migration versions, topology, all writers,
   backup facilities and restore evidence. Record bounded sanitized observations
   and timestamps, keeping private host details and data outside Git. Defer the
   proposed remote inventory workflow if local access provides this evidence.
4. Prepare Step 2's separate persistent-staging PR using observed infrastructure.
   Verify distinct credentials/database/service/endpoint, synthetic fixtures,
   disabled external integrations and persistence across two deployments. The
   existing demo is reseeded and does not satisfy this requirement.
5. Validate PR #78's documented host requirements and perform isolated staging
   promotion, prior-artifact retrieval and concurrent-deployment rehearsals before
   proposing production deployment. Do not equate a passing localhost HTTP check
   with the later semantic schedule checks or database recovery capability.
6. Continue Steps 4–8 in the Phase 0 checklist: backup restoration, semantic smoke
   checks, application rollback, additive-schema compatibility and disaster
   recovery. Record actual durations and losses; close Phase 0 only with evidence.

## Decisions and gates

The requester owns release, recovery and go/no-go decisions. Accepted objectives
are application rollback within **10 minutes**, database recovery within
**60 minutes**, and at most **15 minutes of lost writes**. These are targets;
rehearsals have not demonstrated them. Rollout and artifact/backup retention
windows remain to be agreed. Do not automatically prune designated rollback
artifacts.

Every behavior change follows the repository's role-owned test/review pipeline.
Before every commit, including documentation commits, perform the fresh live
[Bandit patch check](bandit-http2-audit-exception.md). The latest Step 3 check at
2026-10-15T17:06:17Z found installed/latest stable Bandit 1.12.5, no published patch,
and raw audit exit 1 only for EEF-CVE-2026-105659. Seven real protocol tests pass
with HTTP/2 disabled. That historical check never substitutes for the next check.

Keep production deployment as a separately authorized action on a concrete,
reviewed result. No adapter schema or production schedule-data migration belongs
in Phase 0.
