# Historical Friday policy enrichment

This increment follows merged
[PR #101](https://github.com/jeffreybaird/residency-schedule/pull/101) and
[PR #102](https://github.com/jeffreybaird/residency-schedule/pull/102).
It provides explicit, repeatable enrichment of historical task evidence without
rewriting the original classification or changing current schedule readers.
An administrator maintenance page provides the same operation from a phone.

## Why historical evidence needs enrichment

The four `SMH Obstetrics Resident 1st/2nd/3rd/4th Contact Night` tasks originally
shared a generic context policy with gynecology night tasks. PR #101 supplies
an explicit `friday_strong_correction_v1` policy for newly recorded contact-night
classifications. Existing classifications retain their original meaning.

The new evidence lets v2 distinguish the four contact-night tasks without
reinterpreting task labels during reads. It does not introduce a new Friday
correction or approve additional comparison differences.

## Eligibility and history

Only verified legacy QGenda contact-night classifications qualify. Their
`context_required` status and `night_float`/`strong_weekend_nights` targets stay
the same. Eligibility covers occurrences on any date; the existing named policy
decides when Friday and ambulatory context require a correction.

Each append-only attestation binds to the original classification, source
identity, input digest and mapping revision. It records code-origin policy
evidence. It does not invent a human approver or create a replacement
classification.

Original evidence, current source facts and mapping integrity must agree before
an attestation is written. Custom/reviewed records and protected mappings remain
untouched. Deleted or changed sources and contradictory evidence are reported
instead of being guessed. Gynecology night tasks are outside this operation.

## Preview and explicit application

A read-only preview returns aggregate eligibility counts and a bounded review
scope. The scope identifies the policy version and classification watermark;
it is not a human approval of every individual row. Application rechecks current
eligibility and source facts under the existing write lock for each batch.
Records above the reviewed watermark are left for a later preview.

Work is bounded and restartable. Completed batches remain after an interruption;
repeating the operation does not append duplicate attestations. Earlier
classifications are never overwritten to make a conflict disappear.

With the repository/application running, the context API is:

```elixir
alias ResidencySchedule.TaskMappings.FridayEnrichment

{:ok, preview} = FridayEnrichment.preview(batch_size: 500)
preview.counts

# After reviewing the counts, apply only this bounded scope.
{:ok, result} = FridayEnrichment.apply(preview.scope, batch_size: 500)
```

Both scans accept batches of 1–1,000, defaulting to 500. Preview optionally accepts
`schedule_id: id` to select an original schedule scope. Apply uses the schedule
scope and classification cutoff returned by preview, not a replacement filter.

Preview counts `scanned`, `eligible`, `unchanged`, `protected`, `held`,
`conflicting` and `not_applicable`. Apply reports `attested` in place of
`eligible`; these are the rows actually appended. Eligibility is re-evaluated at
application time, so a preview is not a promise that every eligible row will
still qualify. Changed or protected records remain intact.

The operation does not require reseeding current mappings. It validates the
retained original mapping against the canonical code rule and records explicit
policy evidence. Compatible canonical mapping revisions do not erase history.
A protected or contradictory current mapping is held for review.

After schema deployment, use the installed release with the managed runtime
configuration described in [DEPLOY.md](../DEPLOY.md#running-a-release-command-manually).
The trusted operator wrappers are `Release.preview_friday_policy_enrichment/0`
and `Release.apply_friday_policy_enrichment/1`. For example, in the private
release shell on the host:

```elixir
{:ok, preview} = ResidencySchedule.Release.preview_friday_policy_enrichment()
preview.counts

# Review the counts, then apply the returned scope while holding the deployment lock.
ResidencySchedule.Release.apply_friday_policy_enrichment(preview.scope)
```

The preview scope and aggregate counts contain no per-resident review payload.
Keep operational review on the host. Schema deployment and production enrichment
are separate actions; neither deployment nor a read automatically applies this
operation. This document does not establish production execution.

## Administrator page

Open **Admin → Friday policy maintenance**, or visit
`/admin/maintenance/friday-policy`. The page is available only to a currently approved,
non-denied administrator. Preview and apply actions recheck the persisted user;
client-supplied roles or scopes do not authorize a run. The page retains the
reviewed scope on the server and applies that scope after an explicit action.

Preview is read-only. Application runs in the background, independently of the
LiveView connection, so leaving the page does not cancel a started job. One UI
job runs at a time per application node; other sessions can view its status.
The page shows aggregate preview/final counts and running/start/finish status, with
no resident-level evidence payload or SQL errors.

Last-run status is kept in application memory. A server restart can clear that
status; committed attestations remain in the database, and a fresh preview can
be used to continue safely. There is no persistent job platform, automatic
schedule or force-apply action. Existing database guards also protect repeated
or overlapping operator calls.

## Effective reads

V2 loads attestations in a batch and checks their classification/mapping anchors
and critical source facts: source/activity/batch IDs, batch kind/schedule/fingerprint,
membership/person/schedule IDs, literal date, raw task/staff, period and site.
The writer checks the full saved source snapshot, including notes and metadata;
the reader uses these smaller critical anchors. It consumes the stored policy
only when those checks succeed. An invalid present attestation produces a
diagnostic and holds the affected source-derived fact. Reads never run enrichment
or write evidence. Existing direct-v2 classifications retain their current behavior.

With no attestation, existing behavior remains: unsupported historical Friday
evidence stays unresolved. The legacy readers used by current consumers are
unchanged. No assignment, source date, task text, person identity, timing or
coverage override is rewritten by this operation.

## Remaining work

This addresses one evidence-readiness gap in the
[effective-read plan](schedule-effective-read-plan.md). OFF semantics, other
missing or stale identity/classification/timing evidence, consumer comparisons
and read controls remain separate work. Enrichment alone does not authorize
switching consumers to v2.

The [snapshot-and-rebuild decision](schedule-adapter-recovery-decision.md) remains
in effect; no recovery program or backup activation is introduced.
