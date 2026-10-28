# Phase 2 production backfill record

Recorded October 28, 2026 from aggregate counts reported by the production
host. Only counts are recorded; no resident data, labels or configuration
values were copied.

## Deployment

Deployment workflow run 148 for merged
[PR #93](https://github.com/jeffreybaird/residency-schedule/pull/93)
(commit `8ff503f`) succeeded on every job: test, build, staging rehearsal,
production and demo promotion, all on the pinned `ubuntu-24.04` runner. Its
production promotion took 87 seconds against 35 seconds for PR #92, the
difference being migration `20261028190000_run_phase2_backfills` executing
the four backfills during `Release.migrate()`. The migration's own counts went
to the private release evaluation log, which the promotion removes on success.

## Verification reruns

The operator then reran each backfill from the installed production release as
the `deploy` user with the managed configuration (the `DEPLOY.md` command).
Every rerun reported zero new rows:

| Backfill | Result |
| --- | --- |
| `backfill_source_provenance` | `activity_sources_updated: 0` |
| `backfill_identity_mappings` | `observations_added: 0`, `unchanged: 7646`, `conflicting_keys: 0` |
| `backfill_task_classifications` | seed `mappings_added: 0`, `activity_types_added: 0`, `unchanged: 124`, `conflicting: 0`; classifications `processed: 0`, `unchanged: 7646`, `conflicting: 0` |
| `backfill_timings` | `processed: 0`, `unchanged: 7646`, `conflicting: 0` |

The three per-occurrence counts agree on 7,646 saved source occurrences, with
no conflicts, so the identity, classification and timing representations are
complete and consistent with the saved sources. The 124 unchanged mappings are
the seeded legacy task facts. The provenance rerun found no empty QGenda
reference to fill; the repository cannot tell whether the PR #88 backfill was
run earlier or the migration filled the references, and it does not matter for
completeness.

## Status

All Phase 2 additive schemas and backfills are deployed and complete in
production. Existing readers and writers remain authoritative; the next
increment is Phase 3, computing the new effective schedule alongside the
existing reads and comparing consumers.
