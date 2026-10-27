defmodule ResidencySchedule.IdentityMappings.Resolver do
  @moduledoc false
  alias ResidencySchedule.IdentityMappings.{Key, State}

  @doc """
  Resolves a scoped key without changing the legacy importer.

      iex> ctx = ResidencySchedule.IdentityMappingDoctestFixtures.seed()
      iex> {:ok, result} = ResidencySchedule.IdentityMappings.Resolver.resolve(ctx.schedule.id, :qgenda, "Reed, Iris")
      iex> {result.status, result.reason, result.resident_id == ctx.member.resident_id}
      {:matched, :exact_name, true}
  """
  def resolve(schedule_id, namespace, source_key) do
    with {:ok, key} <- Key.normalize(namespace, source_key),
         {:ok, roster} <- State.roster(schedule_id) do
      records =
        schedule_id
        |> State.mappings(namespace)
        |> Enum.filter(&(&1.lookup_key == key.lookup_key))

      {:ok, evaluate(records, roster, key.lookup_key)}
    end
  end

  @doc """
  Evaluates retained evidence against current roster state.

      iex> ctx = ResidencySchedule.IdentityMappingDoctestFixtures.seed()
      iex> {:ok, plan} = ResidencySchedule.IdentityMappings.prepare_crosswalk(ctx.schedule.id, :csv, ctx.rows, ctx.admin)
      iex> {:ok, _counts} = ResidencySchedule.IdentityMappings.approve_crosswalk(plan, ctx.admin)
      iex> {:ok, roster} = ResidencySchedule.IdentityMappings.State.roster(ctx.schedule.id)
      iex> records = ResidencySchedule.IdentityMappings.State.mappings(ctx.schedule.id, :csv)
      iex> result = ResidencySchedule.IdentityMappings.Resolver.evaluate(records, roster, "legacy iris")
      iex> {result.status, result.reason, result.schedule_resident_id == ctx.member.id}
      {:matched, :approved_mapping, true}
  """
  def evaluate(records, roster, lookup_key) do
    approved = Enum.find(records, &(&1.status == "approved" and &1.current))
    observations = Enum.filter(records, &(&1.status == "observed"))
    active = Enum.filter(records, &(&1.status == "observed" or &1.current))
    invalid = Enum.find_value(active, &invalid_target(&1, roster))
    exact = exact_candidates(roster, lookup_key)
    select_result(approved, observations, invalid, exact)
  end

  @doc """
  Finds independent full-name matches, never first-name proposals.

      iex> roster = [%{id: 11, name: "Iris Reed"}, %{id: 12, name: "Juniper Vail"}]
      iex> ResidencySchedule.IdentityMappings.Resolver.exact_candidates(roster, "iris reed")
      [%{id: 11, name: "Iris Reed"}]
  """
  def exact_candidates(roster, lookup_key) do
    if String.contains?(lookup_key, " "),
      do: Enum.filter(roster, &(Key.fold(&1.name) == lookup_key)),
      else: []
  end

  @doc """
  Returns immutable membership/person identity for conflict comparisons.

      iex> snapshot = %{"schedule_resident_id" => 21, "resident_id" => 31, "name" => "Iris Reed"}
      iex> ResidencySchedule.IdentityMappings.Resolver.identity(snapshot)
      {21, 31}
  """
  def identity(snapshot),
    do: {snapshot["schedule_resident_id"], snapshot["resident_id"]}

  defp invalid_target(record, roster) do
    case State.target_status(record, roster) do
      :valid -> if record.evidence_snapshot["historical_drift"], do: :historical_drift
      reason -> reason
    end
  end

  defp select_result(_approved, _observations, reason, _exact) when not is_nil(reason),
    do: result(:held, reason)

  defp select_result(approved, observations, nil, exact) do
    targets = observations |> Enum.map(&identity(&1.target_snapshot)) |> Enum.uniq()

    cond do
      conflicts_with_observations?(approved, targets) ->
        result(:held, :conflicting_observations)

      conflicts_with_exact?(approved, exact) ->
        result(:held, :exact_name_conflict)

      approved ->
        result(:matched, :approved_mapping, approved.target_snapshot, approved.revision)

      multiple_targets?(targets, exact) ->
        result(:ambiguous, :multiple_targets)

      length(exact) == 1 ->
        select_exact(hd(exact), targets)

      observations != [] ->
        result(:held, :observed_only)

      true ->
        result(:unmatched, :no_match)
    end
  end

  defp conflicts_with_observations?(nil, _targets), do: false

  defp conflicts_with_observations?(approved, targets),
    do: Enum.any?(targets, &(&1 != identity(approved.target_snapshot)))

  defp conflicts_with_exact?(nil, _exact), do: false

  defp conflicts_with_exact?(approved, exact),
    do: Enum.any?(exact, &(identity(State.snapshot(&1)) != identity(approved.target_snapshot)))

  defp multiple_targets?(targets, exact), do: length(targets) > 1 or length(exact) > 1

  defp select_exact(member, targets) do
    target = State.snapshot(member)

    if Enum.any?(targets, &(&1 != identity(target))),
      do: result(:held, :conflicting_observations),
      else: result(:matched, :exact_name, target)
  end

  defp result(status, reason, target \\ %{}, revision \\ nil) do
    %{
      status: status,
      reason: reason,
      schedule_resident_id: target["schedule_resident_id"],
      resident_id: target["resident_id"],
      mapping_revision: revision
    }
  end
end
