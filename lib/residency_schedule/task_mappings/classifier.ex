defmodule ResidencySchedule.TaskMappings.Classifier do
  @moduledoc false
  import Ecto.Query
  alias ResidencySchedule.Repo
  alias ResidencySchedule.TaskMappings.{Key, Mapping, Target}

  @rule_version "legacy_task_classification_v1"

  @doc """
  Reads the current mapping without seeding or changing source records.

      iex> {:ok, _counts} = ResidencySchedule.TaskMappings.seed_legacy()
      iex> {:ok, result} = ResidencySchedule.TaskMappings.Classifier.classify(:qgenda, "SMH GYN R2 Day")
      iex> {result.status, result.activity_type_code}
      {:resolved, "strong_gynecology"}
  """
  def classify(namespace, label) do
    with {:ok, key} <- Key.normalize(namespace, label),
         :ok <- seeded(namespace) do
      namespace |> mapping(key.lookup_key) |> result(namespace, key)
    end
  end

  @doc """
  Reads all targets of one revision, preserving multi-target meanings.

      iex> {:ok, _counts} = ResidencySchedule.TaskMappings.seed_legacy()
      iex> {:ok, result} = ResidencySchedule.TaskMappings.classify(:qgenda, "HH Nights 3rd Call")
      iex> ResidencySchedule.TaskMappings.Classifier.targets(result.mapping_id)
      ["highland_night_float", "highland_weekend_nights"]
  """
  def targets(mapping_id) do
    Target
    |> where([target], target.mapping_id == ^mapping_id)
    |> order_by([target], target.activity_type_code)
    |> select([target], target.activity_type_code)
    |> Repo.all()
  end

  @doc """
  Captures actual persisted mapping inputs for later stale-result comparisons.

      iex> {:ok, _counts} = ResidencySchedule.TaskMappings.seed_legacy()
      iex> {:ok, result} = ResidencySchedule.TaskMappings.classify(:qgenda, "HH Nights 3rd Call")
      iex> snapshot = ResidencySchedule.TaskMappings.Classifier.snapshot(result)
      iex> {snapshot["policy"], snapshot["target_codes"]}
      {"highland_saturday_gap_v1", ["highland_night_float", "highland_weekend_nights"]}
  """
  def snapshot(result) do
    result
    |> Map.drop([:status, :activity_type_code])
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
  end

  defp seeded(namespace) do
    present =
      Mapping
      |> where([m], m.namespace == ^Atom.to_string(namespace))
      |> where([m], m.evidence_origin == "legacy_code")
      |> Repo.exists?()

    if present, do: :ok, else: {:error, :not_seeded}
  end

  defp mapping(namespace, lookup_key) do
    Repo.get_by(Mapping,
      namespace: Atom.to_string(namespace),
      lookup_key: lookup_key,
      current: true
    )
  end

  defp result(nil, namespace, key) do
    {:ok,
     %{
       status: :unmapped,
       activity_type_code: nil,
       target_codes: [],
       mapping_id: nil,
       mapping_revision: nil,
       namespace: Atom.to_string(namespace),
       source_label: nil,
       lookup_key: key.lookup_key,
       normalization_version: key.normalization_version,
       recognized: false,
       evidence_origin: "legacy_code",
       evidence_snapshot: %{},
       rule_version: @rule_version,
       policy: "unmapped_v1"
     }}
  end

  defp result(mapping, _namespace, _key) do
    codes = targets(mapping.id)
    status = checked_status(mapping, codes)

    {:ok,
     %{
       status: status,
       activity_type_code: if(status == :resolved, do: hd(codes)),
       target_codes: codes,
       mapping_id: mapping.id,
       mapping_revision: mapping.revision,
       namespace: mapping.namespace,
       source_label: mapping.source_label,
       lookup_key: mapping.lookup_key,
       normalization_version: mapping.normalization_version,
       recognized: mapping.recognized,
       evidence_origin: mapping.evidence_origin,
       evidence_snapshot: mapping.evidence_snapshot,
       rule_version: mapping.rule_version,
       policy: mapping.policy
     }}
  end

  defp checked_status(mapping, codes) do
    if supported_policy?(mapping, codes) and retained_evidence?(mapping, codes),
      do: status(codes, mapping.recognized),
      else: :conflicting
  end

  defp supported_policy?(
         %{
           namespace: "qgenda",
           rule_version: "legacy_task_classification_v2",
           policy: "friday_strong_correction_v1"
         },
         ["night_float", "strong_weekend_nights"]
       ),
       do: true

  defp supported_policy?(mapping, codes) do
    mapping.rule_version == @rule_version and
      mapping.policy == expected_policy(codes, mapping.recognized)
  end

  defp expected_policy([_one], _recognized), do: "unique_equivalence_v1"

  defp expected_policy(["highland_night_float", "highland_weekend_nights"], _recognized),
    do: "highland_saturday_gap_v1"

  defp expected_policy([_one, _two | _rest], _recognized), do: "rotation_context_v1"
  defp expected_policy([], true), do: "recognition_only_v1"
  defp expected_policy([], false), do: "unmapped_v1"

  defp retained_evidence?(%{evidence_origin: "legacy_code"} = mapping, codes) do
    fields = [
      :namespace,
      :source_label,
      :lookup_key,
      :normalization_version,
      :recognized,
      :evidence_origin,
      :rule_version,
      :policy
    ]

    mapping
    |> Map.take(fields)
    |> Map.put(:targets, codes)
    |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)
    |> Kernel.==(mapping.evidence_snapshot)
  end

  defp retained_evidence?(_mapping, _codes), do: true

  defp status([_one], _recognized), do: :resolved
  defp status([_one, _two | _rest], _recognized), do: :context_required
  defp status([], true), do: :recognized_unclassified
  defp status([], false), do: :unmapped
end
