defmodule ResidencySchedule.TaskMappings.FridayPolicyEvidence do
  @moduledoc false
  alias ResidencySchedule.TaskMappings.Legacy

  @targets ["night_float", "strong_weekend_nights"]
  @v1 "legacy_task_classification_v1"
  @v2 "legacy_task_classification_v2"
  @policy "friday_strong_correction_v1"
  @mapping_fields ~w(id namespace source_label lookup_key normalization_version revision recognized evidence_origin rule_version policy)a
  @fact_fields ~w(namespace source_label lookup_key normalization_version recognized evidence_origin rule_version policy)a

  @doc """
  Identifies the exact canonical code facts authorized by this enrichment version.

      iex> {:ok, plan} = ResidencySchedule.TaskMappings.FridayEnrichment.preview()
      iex> plan.scope.policy_fingerprint == ResidencySchedule.TaskMappings.FridayPolicyEvidence.fingerprint()
      true
  """
  def fingerprint do
    facts =
      for rank <- ~w(1st 2nd 3rd 4th) do
        {:ok, fact} = Legacy.friday_policy_fact("SMH Obstetrics Resident #{rank} Contact Night")
        fact
      end

    {1, facts}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  @doc """
  Captures bound attestation fields after the writer verifies original evidence.

      iex> ctx = ResidencySchedule.FridayEnrichmentFixtures.historical_source()
      iex> fields = ResidencySchedule.TaskMappings.FridayPolicyEvidence.attestation_fields(ctx.classification, ctx.graph, ctx.mapping, ["night_float", "strong_weekend_nights"])
      iex> {fields.policy, fields.status, fields.original_input_digest == ctx.classification.input_digest}
      {"friday_strong_correction_v1", "context_required", true}
  """
  def attestation_fields(class, graph, mapping, targets) do
    %{
      classification_id: class.id,
      original_source_id: class.original_source_id,
      original_input_digest: class.input_digest,
      original_mapping_id: class.mapping_id,
      namespace: class.namespace,
      original_mapping_revision: class.mapping_revision,
      original_rule_version: class.rule_version,
      rule_version: @v2,
      policy: @policy,
      status: "context_required",
      target_codes: @targets,
      evidence_origin: "legacy_code",
      policy_fingerprint: fingerprint(),
      original_semantics: semantics(class),
      source_anchor: source_anchor(graph),
      mapping_anchor: mapping_anchor(mapping, targets)
    }
  end

  @doc """
  Overlays valid loaded attestations without reading labels for policy decisions.

      iex> ctx = ResidencySchedule.FridayEnrichmentFixtures.historical_source()
      iex> {:ok, plan} = ResidencySchedule.TaskMappings.FridayEnrichment.preview()
      iex> {:ok, _counts} = ResidencySchedule.TaskMappings.FridayEnrichment.apply(plan.scope)
      iex> inputs = ResidencySchedule.EffectiveSchedule.Inputs.load(ctx.member.schedule_id)
      iex> enriched = ResidencySchedule.TaskMappings.FridayPolicyEvidence.apply(inputs)
      iex> enriched.classifications[ctx.source.id].mapping_snapshot["policy"]
      "friday_strong_correction_v1"
  """
  def apply(inputs) do
    attestations = Map.get(inputs, :friday_attestations, %{})
    activities = Map.new(inputs.activities, &{&1.id, &1})
    sources = source_index(inputs.sources)

    classes =
      Map.new(inputs.classifications, fn {source_id, class} ->
        loaded = Map.get(attestations, Map.get(class, :id))
        graph = if loaded, do: loaded_graph(source_id, sources, activities, inputs.members_by_id)
        {source_id, overlay(class, loaded, graph)}
      end)

    %{inputs | classifications: classes}
  end

  defp overlay(class, nil, _graph), do: class

  defp overlay(class, loaded, graph) do
    if valid_loaded?(class, loaded, graph) do
      snapshot =
        Map.merge(class.mapping_snapshot, %{"rule_version" => @v2, "policy" => @policy})

      %{class | rule_version: @v2, mapping_snapshot: snapshot}
    else
      Map.put(class, :friday_attestation_invalid?, true)
    end
  end

  defp valid_loaded?(_class, _loaded, nil), do: false

  defp valid_loaded?(class, loaded, graph) do
    a = loaded.attestation
    mapping = loaded.original_mapping
    targets = loaded.original_targets || []

    live_class?(class, graph) and old_class?(class) and
      old_mapping?(mapping, targets) and
      compatible_current?(loaded, mapping) and
      same_fields?(a, attestation_fields(class, graph, mapping, targets))
  end

  defp same_fields?(attestation, expected),
    do: Map.take(attestation, Map.keys(expected)) == expected

  defp live_class?(class, graph),
    do:
      class.activity_source_id == class.original_source_id and
        class.original_source_id == graph.source.id and
        graph.batch.source_kind == "qgenda" and
        graph.batch.schedule_id == graph.member.schedule_id

  defp old_class?(class),
    do:
      class.namespace == "qgenda" and class.rule_version == @v1 and
        class.status == "context_required" and is_nil(class.activity_type_code) and
        class.evidence_origin == "legacy_code" and
        class.mapping_snapshot == %{
          "namespace" => "qgenda",
          "rule_version" => @v1,
          "policy" => "rotation_context_v1",
          "target_codes" => @targets
        }

  defp old_mapping?(nil, _targets), do: false

  defp old_mapping?(mapping, targets),
    do:
      canonical_mapping?(mapping, targets) and mapping.rule_version == @v1 and
        mapping.policy == "rotation_context_v1"

  defp compatible_current?(%{current_mapping: nil}, _old), do: true

  defp compatible_current?(loaded, old) do
    current = loaded.current_mapping
    targets = loaded.current_targets || []

    canonical_mapping?(current, targets) and current.source_label == old.source_label and
      current.lookup_key == old.lookup_key and
      {current.rule_version, current.policy} in [
        {@v1, "rotation_context_v1"},
        {@v2, @policy}
      ]
  end

  defp canonical_mapping?(mapping, targets) do
    expected =
      mapping
      |> Map.take(@fact_fields)
      |> Map.put(:targets, targets)
      |> json()

    mapping.namespace == "qgenda" and mapping.evidence_origin == "legacy_code" and
      mapping.recognized and mapping.normalization_version == "qgenda_exact_v1" and
      mapping.source_label == mapping.lookup_key and targets == @targets and
      mapping.evidence_snapshot == expected
  end

  defp source_index(sources) do
    sources
    |> Map.values()
    |> List.flatten()
    |> Map.new(fn {source, namespace} -> {source.id, {source, namespace}} end)
  end

  defp loaded_graph(source_id, sources, activities, members) do
    with {source, namespace} <- Map.get(sources, source_id),
         activity when not is_nil(activity) <- Map.get(activities, source.activity_id),
         member when not is_nil(member) <- Map.get(members, activity.schedule_resident_id) do
      %{
        source: source,
        activity: activity,
        member: member,
        batch: %{
          id: source.batch_id,
          source_kind: namespace,
          schedule_id: source.batch_schedule_id,
          fingerprint: source.batch_fingerprint
        }
      }
    else
      _ -> nil
    end
  end

  defp source_anchor(graph) do
    %{
      source_id: graph.source.id,
      activity_id: graph.source.activity_id,
      batch_id: graph.source.batch_id,
      raw_staff: graph.source.raw_staff,
      batch_kind: graph.batch.source_kind,
      batch_schedule_id: graph.batch.schedule_id,
      batch_fingerprint: graph.batch.fingerprint,
      schedule_resident_id: graph.activity.schedule_resident_id,
      resident_id: graph.member.resident_id,
      schedule_id: graph.member.schedule_id,
      date: graph.activity.date,
      raw_task: graph.activity.raw_task,
      period: graph.activity.period,
      site: graph.activity.site
    }
    |> json()
  end

  defp mapping_anchor(mapping, targets) do
    mapping
    |> Map.take(@mapping_fields)
    |> Map.put(:target_codes, targets)
    |> Map.put(:evidence_snapshot, mapping.evidence_snapshot)
    |> json()
  end

  defp semantics(class) do
    class
    |> Map.take([:namespace, :rule_version, :status, :activity_type_code, :evidence_origin])
    |> Map.put(
      :mapping_snapshot,
      Map.take(class.mapping_snapshot, ~w(namespace rule_version policy target_codes))
    )
    |> json()
  end

  defp json(value), do: value |> Jason.encode!() |> Jason.decode!()
end
