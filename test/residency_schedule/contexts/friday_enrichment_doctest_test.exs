defmodule ResidencySchedule.TaskMappings.FridayEnrichmentDoctestTest do
  use ResidencySchedule.DataCase

  alias ResidencySchedule.TaskMappings.{Backfill, FridayEnrichment, FridayPolicyEvidence, Legacy}

  doctest FridayEnrichment
  doctest FridayPolicyEvidence
  doctest Backfill, only: [source_snapshot: 1, input_digest: 2]
  doctest Legacy, only: [friday_policy_fact: 1]

  doctest ResidencySchedule.Release,
    only: [preview_friday_policy_enrichment: 0, apply_friday_policy_enrichment: 1]
end
