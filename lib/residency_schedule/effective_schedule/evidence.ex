defmodule ResidencySchedule.EffectiveSchedule.Evidence do
  @moduledoc "Interprets retained occurrence facts without reclassifying source labels."
  alias ResidencySchedule.IdentityMappings.{Key, Resolver, State}
  @date_only %{precision: :date_only, period: nil}

  @doc """
  Builds a bounded in-memory diagnostic.

      iex> ResidencySchedule.EffectiveSchedule.Evidence.diagnostic(%{id: 1, schedule_resident_id: 2, date: ~D[2026-11-03]}, nil, :missing_source)
      %{activity_id: 1, activity_source_id: nil, schedule_resident_id: 2, date: ~D[2026-11-03], reason: :missing_source}
  """
  def diagnostic(activity, source_id, reason),
    do: %{
      activity_id: activity.id,
      activity_source_id: source_id,
      schedule_resident_id: activity.schedule_resident_id,
      date: activity.date,
      reason: reason
    }

  @doc """
  Resolves loaded occurrence evidence without reading or writing the database.

      iex> activity = %{id: 1, schedule_resident_id: 2, date: ~D[2026-11-03], raw_task: "Ultrasound"}
      iex> classification = %{status: "resolved", activity_type_code: "ultrasound", namespace: "qgenda", rule_version: "legacy_task_classification_v1", mapping_snapshot: %{"namespace" => "qgenda", "rule_version" => "legacy_task_classification_v1", "policy" => "unique_equivalence_v1", "target_codes" => ["ultrasound"]}}
      iex> inputs = %{activities: [activity], sources: %{1 => [{%{id: 3, raw_staff: "Alias"}, "qgenda"}]}, classifications: %{3 => classification}, timings: %{}, identities: %{}, members_by_id: %{2 => %{id: 2, schedule_id: 4}}}
      iex> {[fact], diagnostics} = ResidencySchedule.EffectiveSchedule.Evidence.resolve(inputs)
      iex> {fact.targets, Enum.sort(Enum.map(diagnostics, & &1.reason))}
      {["ultrasound"], [:missing_identity, :missing_timing]}
  """
  def resolve(inputs) do
    inputs = Map.put(inputs, :identity_results, identity_results(inputs))

    Enum.reduce(inputs.activities, {[], []}, fn activity, {facts, diagnostics} ->
      case Map.get(inputs.sources, activity.id, []) do
        [] ->
          {[fact(activity, nil, [], nil, @date_only) | facts],
           [diagnostic(activity, nil, :missing_source) | diagnostics]}

        sources ->
          resolve_sources(sources, activity, inputs, {facts, diagnostics})
      end
    end)
  end

  defp resolve_sources(sources, activity, inputs, initial) do
    Enum.reduce(sources, initial, fn {source, namespace}, {facts, diagnostics} ->
      {accepted, reasons} = occurrence(activity, source, namespace, inputs)
      {accepted ++ facts, Enum.map(reasons, &diagnostic(activity, source.id, &1)) ++ diagnostics}
    end)
  end

  defp occurrence(activity, source, namespace, inputs) do
    {identity_ok, identity_reasons} =
      Map.fetch!(
        inputs.identity_results,
        {activity.schedule_resident_id, namespace, source.raw_staff}
      )

    {class_ok, targets, policy, class_reasons} =
      classification(Map.get(inputs.classifications, source.id))

    {timing_ok, timing, timing_reasons} = timing(Map.get(inputs.timings, source.id))
    reasons = identity_reasons ++ class_reasons ++ timing_reasons

    if identity_ok and class_ok and timing_ok,
      do: {[fact(activity, source.id, targets, policy, timing)], reasons},
      else: {[], reasons}
  end

  defp identity_results(inputs) do
    Enum.reduce(inputs.activities, %{}, fn activity, cache ->
      cache_identities(activity, inputs, cache)
    end)
  end

  defp cache_identities(activity, inputs, cache) do
    inputs.sources
    |> Map.get(activity.id, [])
    |> Enum.reduce(cache, fn {source, namespace}, cache ->
      key = {activity.schedule_resident_id, namespace, source.raw_staff}
      Map.put_new_lazy(cache, key, fn -> identity(activity, source, namespace, inputs) end)
    end)
  end

  defp fact(activity, source_id, targets, policy, timing),
    do: %{
      activity: activity,
      source_id: source_id,
      targets: targets,
      policy: policy,
      timing: timing
    }

  defp classification(nil), do: {true, [], nil, [:missing_classification]}

  defp classification(c) do
    if supported_classification?(c),
      do: classification_shape(c),
      else: {false, [], nil, [:contradictory_classification]}
  end

  defp supported_classification?(c) do
    snapshot = c.mapping_snapshot

    snapshot["rule_version"] == c.rule_version and snapshot["namespace"] == c.namespace and
      supported_policy?(
        c.rule_version,
        c.namespace,
        snapshot["policy"],
        snapshot["target_codes"],
        c.status
      )
  end

  defp supported_policy?(
         "legacy_task_classification_v2",
         "qgenda",
         "friday_strong_correction_v1",
         ["night_float", "strong_weekend_nights"],
         "context_required"
       ),
       do: true

  defp supported_policy?("legacy_task_classification_v1", namespace, policy, targets, status)
       when namespace in ["csv", "qgenda"] do
    case {policy, targets, status} do
      {"unique_equivalence_v1", [_], "resolved"} ->
        true

      {"highland_saturday_gap_v1", ["highland_night_float", "highland_weekend_nights"],
       "context_required"} ->
        true

      {"rotation_context_v1", [_, _ | _], "context_required"} ->
        targets != ["highland_night_float", "highland_weekend_nights"]

      {"recognition_only_v1", [], "recognized_unclassified"} ->
        true

      {"unmapped_v1", [], "unmapped"} ->
        true

      _ ->
        false
    end
  end

  defp supported_policy?(_, _, _, _, _), do: false

  defp classification_shape(c) do
    targets = Map.get(c.mapping_snapshot, "target_codes", [])
    policy = Map.get(c.mapping_snapshot, "policy")

    case {c.status, targets, c.activity_type_code} do
      {"resolved", [code], code} when is_binary(code) -> {true, targets, policy, []}
      {"context_required", [_a, _b | _], nil} -> {true, targets, policy, []}
      {"recognized_unclassified", [], nil} -> {true, [], policy, []}
      {"unmapped", [], nil} -> {true, [], policy, [:unmapped_classification]}
      _ -> {false, [], nil, [:contradictory_classification]}
    end
  end

  defp timing(nil), do: {true, @date_only, [:missing_timing]}

  defp timing(%{
         precision: "date_only",
         period: nil,
         starts_at: nil,
         ends_at: nil,
         time_zone: nil,
         rule_version: "legacy_timing_v1",
         policy: "date_only"
       }),
       do: {true, @date_only, []}

  defp timing(%{
         precision: "period",
         period: period,
         starts_at: nil,
         ends_at: nil,
         time_zone: nil,
         rule_version: "legacy_timing_v1",
         policy: "stored_period"
       })
       when period in ["AM", "PM", "Day", "Night"],
       do: {true, %{precision: :period, period: period}, []}

  defp timing(%{
         precision: "exact",
         period: nil,
         starts_at: %DateTime{} = first,
         ends_at: %DateTime{} = last,
         time_zone: zone,
         rule_version: "legacy_timing_v1",
         policy: "exact_source"
       }) do
    if is_binary(zone) and zone != "" and DateTime.before?(first, last),
      do:
        {true,
         %{precision: :exact, period: nil, starts_at: first, ends_at: last, time_zone: zone}, []},
      else: {false, @date_only, [:contradictory_timing]}
  end

  defp timing(_), do: {false, @date_only, [:contradictory_timing]}

  defp identity(activity, source, namespace, inputs) do
    member = Map.fetch!(inputs.members_by_id, activity.schedule_resident_id)

    case Key.normalize(namespace_atom(namespace), source.raw_staff) do
      {:ok, key} ->
        records = Map.get(inputs.identities, {member.schedule_id, namespace, key.lookup_key}, [])
        evaluate_identity(records, member, inputs)

      _ ->
        {false, [:contradictory_identity]}
    end
  end

  defp namespace_atom("qgenda"), do: :qgenda
  defp namespace_atom("csv"), do: :csv
  defp namespace_atom(_), do: nil

  defp evaluate_identity([], _member, _inputs), do: {true, [:missing_identity]}

  defp evaluate_identity(records, member, inputs) do
    active = Enum.filter(records, &(&1.current or &1.status == "observed"))
    approved = Enum.filter(active, &(&1.status == "approved"))

    observed =
      active
      |> Enum.filter(&(&1.status == "observed"))
      |> Enum.map(&Resolver.identity(&1.target_snapshot))
      |> Enum.uniq()

    roster = Enum.filter(inputs.members, &(&1.schedule_id == member.schedule_id))
    expected = {member.id, member.resident_id}

    cond do
      Enum.any?(approved, &(Resolver.identity(&1.target_snapshot) != expected)) ->
        {false, [:contradictory_identity]}

      length(observed) > 1 ->
        {false, [:ambiguous_identity]}

      Enum.any?(
        active,
        &(State.target_status(&1, roster) != :valid or
              &1.evidence_snapshot["historical_drift"] == true)
      ) ->
        {false, [:held_identity]}

      approved == [] ->
        {false, [:held_identity]}

      Enum.any?(observed, &(&1 != expected)) ->
        {false, [:contradictory_identity]}

      true ->
        {true, []}
    end
  end
end
