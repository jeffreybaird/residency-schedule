defmodule ResidencySchedule.TaskMappings do
  @moduledoc """
  Additive legacy task meaning and retained source classifications.

  Recognition is separate from service equivalence. Existing schedule readers
  remain authoritative; this representation does not change dates or assignments.
  """
  alias ResidencySchedule.TaskMappings.{Backfill, Classifier, Key, Legacy}

  @doc """
  Normalizes a label with its closed source namespace's existing policy.

      iex> ResidencySchedule.TaskMappings.normalize_key(:qgenda, "SMH GYN R2 Day")
      {:ok, %{lookup_key: "SMH GYN R2 Day", normalization_version: "qgenda_exact_v1"}}
  """
  defdelegate normalize_key(namespace, label), to: Key, as: :normalize

  @doc """
  Seeds existing legacy facts without inventing human approval or overwriting custom facts.

      iex> {:ok, counts} = ResidencySchedule.TaskMappings.seed_legacy()
      iex> {counts.mappings_added > 0, counts.conflicting}
      {true, 0}
  """
  defdelegate seed_legacy(), to: Legacy, as: :seed

  @doc """
  Returns a read-only interpretation after explicit seeding.

      iex> {:ok, _counts} = ResidencySchedule.TaskMappings.seed_legacy()
      iex> {:ok, result} = ResidencySchedule.TaskMappings.classify(:qgenda, "HH Nights 3rd Call")
      iex> {result.status, result.target_codes}
      {:context_required, ["highland_night_float", "highland_weekend_nights"]}
  """
  defdelegate classify(namespace, label), to: Classifier

  @doc """
  Fills missing occurrence results in restartable batches of 1–1000 (default 500).

  Historical results with changed inputs or rules are reported as conflicts and
  retained. Reviewed/custom results are unchanged; custom mappings are not
  automatically attributed to legacy code. No source record is rewritten.

      iex> _ctx = ResidencySchedule.TaskMappingDoctestFixtures.source()
      iex> {:ok, _seed} = ResidencySchedule.TaskMappings.seed_legacy()
      iex> {:ok, result} = ResidencySchedule.TaskMappings.backfill(batch_size: 1)
      iex> {result.processed, result.resolved, result.unchanged}
      {1, 1, 0}
  """
  def backfill(options \\ []), do: Backfill.run(options)
end
