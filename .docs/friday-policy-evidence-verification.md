# Friday correction policy evidence

Recorded October 28, 2026 on baseline
`df22dab8a63c4caef493c0c994c99f6715594950`, following PR #100.

## Why evidence needs enrichment

Legacy Friday correction distinguishes four Obstetrics Contact Night task labels
from gynecology night tasks. Phase 2 stored both with the same generic context
policy and Strong night target pair, so an evidence-only reader could not retain
that distinction without interpreting labels again.

This bounded prerequisite assigns only those four contact-night mapping facts
rule version `legacy_task_classification_v2` and policy
`friday_strong_correction_v1`. Recognition, target codes and `context_required`
classification remain unchanged. Gynecology night facts retain their existing
generic policy. The classifier validates the new supported combination and its
retained evidence without a raw-label decision at read time.

Seeding appends new mapping revisions and preserves historical snapshots. The
existing explicit backfill creates new occurrence classifications only where
missing; it does not replace retained occurrence interpretations. No seeding or
backfill is run in production by this change.

## Historical readiness limitation

An existing occurrence classification is immutable and has unique original source
identity. Re-seeding then running the existing backfill reports changed evidence
as a conflict rather than overwriting that row. V2 must report insufficient policy
evidence for historical generic contact-night classifications. This is not a
completed production-readiness gate.

Refreshing historical interpretation safely requires a separately designed
append-only classification revision API/storage change or a policy-attestation
record tied to the retained classification and mapping revision. Neither is part
of this no-migration prerequisite. No common writer overhaul, production data
change, schema migration, consumer switch or deployment is included.

## Accepted contract and red

The spec writer added five tests in
`test/residency_schedule/contexts/friday_policy_evidence_test.exs`, using actual
persisted v1 mapping facts and occurrence evidence before the upgrade. Tests cover
exactly four enriched labels, unchanged contextual targets, gynecology controls,
append-only mapping revisions, retained old occurrence snapshots, new occurrence
snapshots, repeatability, custom mappings and invalid policy combinations.

Reviewer accepted SHA256:
`46f076e74f0f61846fed912b3557881e2a22b030f87270780955c1840f7bde00`.
Runner pre-implementation red: five tests, three expected failures, seed 839032.
The enriched facts were missing, the old mapping remained current, and invalid
CSV policy metadata was classified rather than rejected. Two existing preservation
behaviors already passed. No setup or compilation failures occurred.

The initial focused green run exposed a setup issue after earlier red assertions
were satisfied: a second activity with identical member/date/task violated the
existing activity-identity uniqueness constraint. The spec writer changed this
to a second source occurrence of the existing activity, preserving all expected
history/status/count assertions. Reviewer reaccepted the setup-only correction.
Final test SHA256:
`dde88573596eeb231d204b5ce04bc92adda902c302833c6753cd36e04d95713e`.

Before this prerequisite the spec writer froze incomplete, unaccepted v2 drafts.
The orchestrator preserved only those four test paths plus their design document
with a path-scoped Git stash. The audit flags the observed test removals against
that Git command; independent review classified this as permitted Git
preservation, not authored test changes. Draft restoration must compare their
recorded hashes before further edits. Owned formatter entries have no violations.

## Final verification

- Focused task mapping tests: 15 doctests, 27 tests, zero failures, seed 908559.
- Full `mix test`: 302 doctests, 1979 tests, zero failures, seed 488037,
  56.1 seconds.
- `mix format --check-formatted`, `MIX_ENV=test mix compile --warnings-as-errors`,
  `mix deps.unlock --check-unused`: exit zero.
- `mix credo --strict`: 380 files, 3069 modules/functions, no issues.
- Reaccepted test SHA256 unchanged.
- Independent fresh `mix hex.audit`: no retired or advisory packages. Hex-only
  coverage; production exposure was not inspected.
