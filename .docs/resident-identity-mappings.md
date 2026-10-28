# Resident identity mappings: first mapping increment

This delivery implements PR 1 of the
[mappings and classifications plan](schedule-mappings-classifications-plan.md).
It adds persistent identity evidence and explicit reusable approvals. Task
classifications, exact timing, a mapping-management UI and reader/writer cutover
are separate work.

## Scope and representation

Mappings use the closed namespaces `:csv` and `:qgenda`, scoped to a selected
schedule. The year comes from that schedule. The namespace is a logical source
domain, not a filename; a position code alone never establishes a person's
identity across years.

`source_identity_mappings` stores observed and approved revisions with literal
source keys, versioned lookup normalization, evidence origin and target snapshots.
The target snapshot captures the actual schedule, membership, derived stable
person, position and name. Actor attribution is recorded only where established.

Observed revisions record saved source-to-membership associations; they do not
approve future reuse. Approved revisions require a separate administrator action.
A current flag describes applicability without changing the historical target's
meaning. The schema prevents multiple current approved targets for the same
namespace, schedule and lookup key.

Live schedule/membership references are nullable on deletion, while the original
scope and snapshot remain. A composite membership/schedule constraint prevents
cross-schedule targets. Replacing a CSV roster can therefore proceed without
erasing historical evidence or silently rebinding an approval to a new occupant
of the same `Rn-n` position. An unavailable target resolves as held. Existing
protections on replacing schedules with saved QGenda detail remain unchanged.

## Lookup and comparison

`ResidencySchedule.IdentityMappings.normalize_key(namespace, source_key)` returns
the lookup key and normalization version. CSV uses its whitespace/case policy;
QGenda preserves the current directory-name conversion and full-name guard.
No strings from uploaded data are turned into arbitrary atoms.

`IdentityMappings.resolve(schedule_id, namespace, source_key)` returns a tagged
result with a status, reason, target membership/person IDs where established,
and mapping revision. Statuses are matched, unmatched, ambiguous or held.

An observed alias is not enough to match a future upload. Independent unambiguous
full-name matching may establish a match. This shadow API requires a multiword
name for that fallback in both namespaces; single-name aliases require explicit
approval. Existing CSV first-name matching stays in the existing importer and
does not become a reusable approval. Conflicting observations remain explicit.
Approved mappings whose target is missing, reassigned or no longer agrees with
the snapshot are held rather than repaired by guesswork.

These APIs support explicit comparison with existing matching. Existing upload
previews and commits remain authoritative and do not automatically consult or
save reusable mappings in this increment. Source-content fingerprints, resident
names, activities and committed source-cell identities are unchanged.

## Explicit crosswalk approval

With the application/repository running and the actual administrator user:

```elixir
alias ResidencySchedule.IdentityMappings

# Fictional example: expected_name must match the selected current roster.
rows = [%{source_key: "Reed, Iris", position_code: "R2-1", expected_name: "Iris Reed"}]
{:ok, plan} = IdentityMappings.prepare_crosswalk(schedule_id, :qgenda, rows, admin)

# Inspect the plan's additions, existing matches, held rows and conflicts.
# Only approve a reviewed, conflict-free plan.
{:ok, result} = IdentityMappings.approve_crosswalk(plan, admin)
```

Preparation is read-only, with 1–1,000 rows and source keys of at most 512 bytes.
Approval returns counts of approved and
unchanged mappings. Both calls recheck the actor's current stored administrator
access. Approval reconstructs and revalidates the proposed rows under the existing
write lock, including roster and mapping snapshots. Stale or conflicting plans
are rejected atomically; prepare and review again rather than bypassing checks.
`expected_name` must equal the actual stored roster name; it may be a legacy
canonical first name rather than the full source display name.

The API accepts reviewed row maps; it does not assume that a private configured
crosswalk exists in Git or on the server. An uploaded crosswalk in the current
QGenda preview remains temporary. Supplying a file to that preview is not approval
to save reusable mappings. No existing activity or source cell is reassigned by
approving a mapping.

## Observation backfill

The additive migration creates the new representation without rewriting existing
assignments. A separate bounded backfill observes current saved QGenda activity
sources and their existing membership associations. It records real evidence
without inventing a reusable approver, source staff ID or historical decision.

After the reviewed schema is deployed, use the installed release and its existing
managed runtime/operator configuration and deployment lock:

```sh
bin/residency_schedule eval 'IO.inspect(ResidencySchedule.Release.backfill_identity_mappings())'
```

Migration `20261028190000_run_phase2_backfills` runs this backfill once during `Release.migrate()` on the next deployment (the `:run_phase2_backfills_on_migrate` flag is off in the test environment); the manual command above remains the verification and rerun path and reports zero new rows once the migration has run. The context API is `IdentityMappings.backfill(options)`, with `batch_size`
defaulting to 500 and accepting 1–1,000. Its result includes
`observations_added`, `unchanged` and `conflicting_keys` counts. Repeating a
completed backfill adds zero observations; unchanged/conflict counts may still
be nonzero. Interrupted work can be rerun. Backfill does not turn observed
associations into approved mappings or change current importer matching.
Blank, invalid or oversized source keys are skipped without a separate count.
`conflicting_keys` counts all retained distinct scoped keys with conflicting
observed targets, including conflicts recorded by earlier runs.

Use synthetic data for migration, conflict and stale-plan tests. The
[verification record](resident-identity-mappings-verification.md) distinguishes
local results from actual deployment and backfill execution. Production execution
is not established by this document.

The [snapshot-and-rebuild decision](schedule-adapter-recovery-decision.md) remains
in effect. This increment introduces no backup activation or recovery program.
