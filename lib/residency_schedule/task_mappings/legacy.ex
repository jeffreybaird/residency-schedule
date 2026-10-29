defmodule ResidencySchedule.TaskMappings.Legacy do
  @moduledoc false
  import Ecto.Query

  alias ResidencySchedule.DetailedSchedules.TaskEquivalence
  alias ResidencySchedule.Importer.{CsvParser, QgendaPreview}
  alias ResidencySchedule.{Repo, Rotations}
  alias ResidencySchedule.ScheduleCache.Revision
  alias ResidencySchedule.TaskMappings.{ActivityType, Classifier, Key, Mapping, Target}

  @rule_version "legacy_task_classification_v1"
  @contact_nights for rank <- ~w(1st 2nd 3rd 4th),
                      do: "SMH Obstetrics Resident #{rank} Contact Night"

  @doc """
  Seeds the existing reviewed code facts atomically, preserving earlier revisions.

  Contact-night mappings retain their targets and gain versioned Friday policy
  evidence. Existing occurrence classifications remain immutable; backfill reports
  their older mapping snapshots as conflicts rather than rewriting them.

      iex> {:ok, counts} = ResidencySchedule.TaskMappings.Legacy.seed()
      iex> {counts.activity_types_added > 0, counts.mappings_added > 0, counts.conflicting}
      {true, true, 0}
  """
  def seed do
    Repo.transaction(fn ->
      Revision.lock()
      types = seed_types()
      initial = %{activity_types_added: types, mappings_added: 0, unchanged: 0, conflicting: 0}
      Enum.reduce(facts(), initial, &seed_fact/2)
    end)
  end

  defp seed_types do
    Rotations.all_rotation_types()
    |> Enum.reject(&(&1 in ["unknown", "qgenda_assignment"]))
    |> Enum.sort()
    |> Enum.count(fn code ->
      if Repo.get_by(ActivityType, code: code) do
        false
      else
        label = Rotations.rotation_type_label(code)
        Repo.insert!(%ActivityType{code: code, label: label, description: label})
        true
      end
    end)
  end

  defp facts do
    csv =
      CsvParser.rotation_abbreviations()
      |> Enum.map(fn {label, code} -> fact(:csv, label, true, [code]) end)

    equivalents = TaskEquivalence.equivalences()
    recognized = QgendaPreview.known_tasks()

    qgenda =
      (recognized ++ Map.keys(equivalents))
      |> Enum.uniq()
      |> Enum.sort()
      |> Enum.map(&fact(:qgenda, &1, &1 in recognized, Map.get(equivalents, &1, [])))

    Enum.sort_by(csv ++ qgenda, &{&1.namespace, &1.lookup_key})
  end

  defp fact(namespace, label, recognized, targets) do
    {:ok, key} = Key.normalize(namespace, label)
    targets = Enum.sort(targets)

    %{
      namespace: Atom.to_string(namespace),
      source_label: label,
      lookup_key: key.lookup_key,
      normalization_version: key.normalization_version,
      recognized: recognized,
      evidence_origin: "legacy_code",
      rule_version: @rule_version,
      policy: policy(targets, recognized),
      targets: targets
    }
    |> enrich_friday_policy()
  end

  defp enrich_friday_policy(
         %{
           namespace: "qgenda",
           source_label: label,
           targets: ["night_float", "strong_weekend_nights"]
         } = fact
       )
       when label in @contact_nights do
    %{fact | rule_version: "legacy_task_classification_v2", policy: "friday_strong_correction_v1"}
  end

  defp enrich_friday_policy(fact), do: fact

  defp policy([_one], _recognized), do: "unique_equivalence_v1"

  defp policy(["highland_night_float", "highland_weekend_nights"], _recognized),
    do: "highland_saturday_gap_v1"

  defp policy([_one, _two | _rest], _recognized), do: "rotation_context_v1"
  defp policy([], true), do: "recognition_only_v1"
  defp policy([], false), do: "unmapped_v1"

  defp seed_fact(fact, counts) do
    current =
      Mapping
      |> where([m], m.namespace == ^fact.namespace and m.lookup_key == ^fact.lookup_key)
      |> where([m], m.current)
      |> lock("FOR UPDATE")
      |> Repo.one()

    cond do
      current && current.evidence_origin != "legacy_code" ->
        Map.update!(counts, :conflicting, &(&1 + 1))

      current && same_fact?(current, fact) ->
        Map.update!(counts, :unchanged, &(&1 + 1))

      true ->
        append_fact(current, fact)
        Map.update!(counts, :mappings_added, &(&1 + 1))
    end
  end

  defp same_fact?(current, fact) do
    fields = Map.keys(Map.delete(fact, :targets))

    Map.take(current, fields) == Map.take(fact, fields) and
      Classifier.targets(current.id) == fact.targets and
      current.evidence_snapshot == evidence(fact)
  end

  defp append_fact(current, fact) do
    if current,
      do: Mapping |> where([m], m.id == ^current.id) |> Repo.update_all(set: [current: false])

    revision =
      Mapping
      |> where([m], m.namespace == ^fact.namespace and m.lookup_key == ^fact.lookup_key)
      |> select([m], max(m.revision))
      |> Repo.one()
      |> then(&((&1 || 0) + 1))

    attrs =
      fact
      |> Map.delete(:targets)
      |> Map.merge(%{revision: revision, current: true, evidence_snapshot: evidence(fact)})

    mapping = Repo.insert!(struct!(Mapping, attrs))

    Enum.each(fact.targets, fn code ->
      Repo.insert!(%Target{mapping_id: mapping.id, activity_type_code: code})
    end)
  end

  defp evidence(fact), do: Map.new(fact, fn {key, value} -> {Atom.to_string(key), value} end)
end
