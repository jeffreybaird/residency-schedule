# Local agent handoff: finish source provenance, then continue the model plan

Prepared October 21, 2026. Repository:
[jeffreybaird/residency-schedule](https://github.com/jeffreybaird/residency-schedule).

## Current state

- [PR #87](https://github.com/jeffreybaird/residency-schedule/pull/87) is merged at
  `3889cf4525de26f8c515824af4305c4568af19b6`. It introduced the adapter boundary
  and retired the old recovery program.
- [PR #88](https://github.com/jeffreybaird/residency-schedule/pull/88) is open and
  ready for review as of this handoff. Branch: `codex/schedule-source-provenance`.
  Implementation commit: `bda74db84d41b18f7dbcdecacc305baa37482175`.
  This handoff is a documentation follow-up on the same branch.
- [PR CI for the implementation commit](https://github.com/jeffreybaird/residency-schedule/actions/runs/39651567272)
  completed successfully. Refresh checks on the latest head; this historical
  result does not certify later commits or a production deployment.
- Local synthetic validation passed **220 doctests and 1,769 tests**, including
  12 provenance/migration tests, plus formatting, warnings-as-errors compilation,
  strict Credo, unused-lock checks, fresh Hex advisory checks and independent review.
- No production migration, backfill or deployment was performed in this session.
  Live production state, current snapshot availability and local credentials were
  not verified. Do not infer them from source or CI.

## Owner decisions and scope

This app serves four family members and changes infrequently. The owner canceled
the old Phase 0 recovery program, rather than deferring it. The accepted fallback
is rebuilding the server and restoring an available database snapshot, with
downtime and post-snapshot write loss accepted. **Do not resume backup activation,
PITR, monitoring provisioning, recovery targets, drills or Phase 0 closeout.**
Keep delivered tools and ordinary correctness tests. See the
[recovery decision](schedule-adapter-recovery-decision.md).

The owner requested the source/provenance step. Each additive schema step includes
its own backfill and validation. The order is:

1. Source provenance and its backfill — implemented in PR #88; finish delivery.
2. Mappings and classifications, with their own backfill.
3. Timing metadata, with its own backfill.

Later phases compare new reads, enable them, move writes and retire compatibility.
Do not bundle those phases into finishing PR #88. This handoff does not itself
authorize a merge or production operation; reuse any subsequent owner approval
for the actual reviewed change.

## Resume locally

1. Locate the local checkout. An earlier session recorded
   `/Users/jeffreybaird/src/residency-schedule`; verify it exists rather than
   assuming the path. Inspect dirty files and worktrees and preserve existing work.
2. Read `AGENTS.md`, [project guidance](project-guidance.md),
   [agent workflow](agent-workflow.md), [the model plan](schedule-adapter-release-plan.md),
   [source-provenance contract](schedule-source-provenance.md),
   [verification record](schedule-source-provenance-verification.md), and
   [deployment guide](../DEPLOY.md). Use the required role-owned test/review
   workflow for any behavior fixes. Do not weaken accepted tests.
3. Fetch current GitHub state and inspect PR #88's latest head, checks and review
   comments. Work on its branch in a clean checkout/worktree. If it has already
   merged, continue from current `main`; do not reapply the implementation.
4. Use existing local GitHub, SSH and hosting configuration. The cloud execution
   environment had no production credential bindings, and `/workspace/.setup`
   was only its local test toolchain. Do not copy that path into the local setup,
   invent hosts/credentials, or print tokens, cookies or runtime configuration.

## What PR #88 changes

- `detailed_import_batches`: `source_kind` (existing batches are known QGenda)
  and `source_metadata`.
- `detailed_activity_sources`: generic `source_reference` maps, without removing
  sheet/cell columns or changing occurrence identity, notes or fingerprints.
- `rotations`: `source_kind` and `source_metadata`. Unknown historical origins
  become `legacy`; no filenames, actors or upload times are invented.
- Current CSV, builder and editor writes record their origin. Rotation provenance
  is the latest writing origin, not a full audit history. Editor changes clear
  stale metadata; no-op saves preserve it. Date-update fragments retain prior
  provenance. JSON remains preview-only.
- Migration: `20261021180835_add_source_provenance.exs`. It adds columns/defaults;
  worksheet/cell backfill is a separate bounded command.
- API: `ResidencySchedule.SourceProvenance.backfill(batch_size: 500)` accepts
  sizes 1–1,000. It fills only empty QGenda references and preserves populated
  references, other source kinds and original timestamps.

## Finish delivery and backfill

Address actual PR findings and refresh the relevant checks. The complete prior
validation is in the verification record; do not claim those checks ran locally
unless you run them. If no code changes are needed, avoid reimplementing the work.

Coordinate the reviewed merge/deployment with the owner. Merging to `main` uses
the existing deployment workflow; inspect its actual result and deployed release.
Do not treat the merged flag as deployment success. Verify migration
`20261021180835` is applied on the intended database before calling the new task.

Before the production data change, note the snapshot being relied on and use the
existing server/deployment instructions. This is the simple accepted fallback,
not a requirement to rebuild the retired recovery program.

Using the intended installation, operator identity, managed runtime configuration
and existing deployment lock described in `DEPLOY.md`, run from the installed
release (not with Mix on the server):

```sh
bin/residency_schedule eval 'IO.inspect(ResidencySchedule.Release.backfill_source_provenance())'
```

Expected output: `{:ok, %{activity_sources_updated: count}}`. Run it again after
success; a completed repeat should return zero. Zero on the first call can mean
there were no eligible sources or another operator already completed it. Confirm
that state rather than inventing a positive expected count. If interrupted or
returned `{:error, ...}`, investigate and rerun after correcting the cause.

Record the actual release/migration identity, deployment outcome and aggregate
backfill counts. Check representative schedule results and retained notes/links
through existing authorized views without putting resident data or tokens in Git.
Do not claim production completion until it has been observed.

## Report back and next work

Report PR/review status, deployed commit and workflow outcome when applicable,
migration verification, first/repeated backfill counts, and any actual blocker.
If review or deployment is still pending, identify that next action explicitly.

Once this delivery is complete, the next model increment is mappings and
classifications with its own tests and backfill. Timing metadata follows it.
Keep current readers/writers and stable IDs until the later transition phases.
