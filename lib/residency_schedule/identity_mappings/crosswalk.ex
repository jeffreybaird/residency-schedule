defmodule ResidencySchedule.IdentityMappings.Crosswalk do
  @moduledoc false
  import Ecto.Query

  alias ResidencySchedule.IdentityMappings.{Key, Mapping, Resolver, State}
  alias ResidencySchedule.Repo
  alias ResidencySchedule.ScheduleCache.Revision

  @doc """
  Prepares a read-only administrator review against actual roster state.

      iex> ctx = ResidencySchedule.IdentityMappingDoctestFixtures.seed()
      iex> {:ok, plan} = ResidencySchedule.IdentityMappings.Crosswalk.prepare(ctx.schedule.id, :csv, ctx.rows, ctx.admin)
      iex> plan.summary
      %{additions: 1, existing: 0, held: 0, conflicts: 0}
      iex> ResidencySchedule.IdentityMappings.State.mappings(ctx.schedule.id, :csv)
      []
  """
  def prepare(schedule_id, namespace, rows, user) do
    with {:ok, _actor} <- State.admin(user),
         {:ok, _key} <- Key.normalize(namespace, "validation"),
         {:ok, canonical} <- validate_rows(rows, namespace),
         {:ok, roster} <- State.roster(schedule_id) do
      mappings = State.mappings(schedule_id, namespace)
      actions = Enum.map(canonical, &review_row(&1, namespace, roster, mappings))

      plan = %{
        version: 1,
        schedule_id: schedule_id,
        namespace: namespace,
        rows: canonical,
        state: State.review_state(roster, mappings),
        summary: count_actions(actions)
      }

      {:ok, Map.put(plan, :review_digest, digest(plan))}
    end
  end

  @doc """
  Rechecks a review and appends approved revisions atomically.

      iex> ctx = ResidencySchedule.IdentityMappingDoctestFixtures.seed()
      iex> {:ok, plan} = ResidencySchedule.IdentityMappings.Crosswalk.prepare(ctx.schedule.id, :csv, ctx.rows, ctx.admin)
      iex> ResidencySchedule.IdentityMappings.Crosswalk.approve(plan, ctx.admin)
      {:ok, %{approved: 1, unchanged: 0}}
      iex> {:ok, result} = ResidencySchedule.IdentityMappings.resolve(ctx.schedule.id, :csv, "Legacy Iris")
      iex> {result.reason, result.schedule_resident_id == ctx.member.id}
      {:approved_mapping, true}
  """
  def approve(plan, user) do
    with {:ok, _actor} <- State.admin(user),
         :ok <- validate_plan(plan) do
      Repo.transaction(fn -> approve_locked(plan, user) end)
    end
  rescue
    _error in [Postgrex.Error, Ecto.ConstraintError] -> {:error, :retryable}
  end

  defp approve_locked(plan, user) do
    Revision.lock()

    with {:ok, actor} <- State.admin(user, true),
         {:ok, fresh} <- prepare(plan.schedule_id, plan.namespace, plan.rows, actor),
         :ok <- validate_fresh(plan, fresh),
         :ok <- validate_summary(fresh.summary) do
      persist_rows(fresh, actor)
    else
      {:error, reason} -> Repo.rollback(reason)
    end
  end

  defp validate_plan(%{version: 1, review_digest: token} = plan) when is_binary(token) do
    required = [:schedule_id, :namespace, :rows, :state, :summary]

    if Enum.all?(required, &Map.has_key?(plan, &1)) and digest(plan) == token,
      do: :ok,
      else: {:error, :invalid_plan}
  end

  defp validate_plan(_plan), do: {:error, :invalid_plan}

  defp validate_fresh(plan, fresh) do
    if plan.review_digest == fresh.review_digest,
      do: :ok,
      else: {:error, :stale_plan}
  end

  defp validate_summary(%{conflicts: conflicts}) when conflicts > 0, do: {:error, :conflict}
  defp validate_summary(%{held: held}) when held > 0, do: {:error, :held}
  defp validate_summary(_summary), do: :ok

  defp validate_rows(rows, namespace) when is_list(rows) and length(rows) in 1..1000 do
    canonical = Enum.map(rows, &canonical_row/1)

    if Enum.all?(canonical, &valid_row?(&1, namespace)) and unique_rows?(canonical, namespace),
      do: {:ok, canonical},
      else: {:error, :invalid_crosswalk}
  end

  defp validate_rows(_rows, _namespace), do: {:error, :invalid_crosswalk}

  defp canonical_row(row) when is_map(row) do
    %{
      source_key: Map.get(row, :source_key, Map.get(row, "source_key")),
      position_code: Map.get(row, :position_code, Map.get(row, "position_code")),
      expected_name: Map.get(row, :expected_name, Map.get(row, "expected_name"))
    }
  end

  defp canonical_row(_row), do: %{}

  defp valid_row?(%{source_key: key, position_code: code, expected_name: name}, namespace) do
    match?({:ok, _}, Key.normalize(namespace, key)) and Key.valid_literal?(name) and
      is_binary(code) and byte_size(code) <= 32 and Regex.match?(~r/^R[1-4]-[1-9][0-9]*$/, code)
  end

  defp valid_row?(_row, _namespace), do: false

  defp unique_rows?(rows, namespace) do
    keys =
      Enum.map(rows, fn row ->
        {:ok, key} = Key.normalize(namespace, row.source_key)
        key.lookup_key
      end)

    positions = Enum.map(rows, & &1.position_code)
    length(Enum.uniq(keys)) == length(keys) and length(Enum.uniq(positions)) == length(positions)
  end

  defp review_row(row, namespace, roster, mappings) do
    {:ok, key} = Key.normalize(namespace, row.source_key)
    records = Enum.filter(mappings, &(&1.lookup_key == key.lookup_key))

    member =
      Enum.find(roster, &(&1.position_code == row.position_code and &1.name == row.expected_name))

    observations = Enum.filter(records, &(&1.status == "observed"))
    resolution = Resolver.evaluate(observations, roster, key.lookup_key)
    approved = Enum.find(records, &(&1.status == "approved" and &1.current))

    classify_row(member, records, approved, resolution, roster, key.lookup_key)
  end

  defp classify_row(nil, _records, _approved, _resolution, _roster, _key), do: :held

  defp classify_row(member, records, approved, resolution, roster, key) do
    target = State.snapshot(member)
    observations = Enum.filter(records, &(&1.status == "observed"))
    exact = Resolver.exact_candidates(roster, key)

    cond do
      blocking_hold?(resolution) ->
        :held

      contradicts_approval?(approved, observations, roster) ->
        :conflicts

      resolution.status == :ambiguous ->
        :conflicts

      Enum.any?(
        observations,
        &(Resolver.identity(&1.target_snapshot) != Resolver.identity(target))
      ) ->
        :conflicts

      Enum.any?(exact, &(&1.id != member.id)) ->
        :conflicts

      same_approval?(approved, target) ->
        :existing

      true ->
        :additions
    end
  end

  defp blocking_hold?(resolution),
    do: resolution.status == :held and resolution.reason != :observed_only

  defp contradicts_approval?(nil, _observations, _roster), do: false

  defp contradicts_approval?(approved, observations, roster) do
    State.target_status(approved, roster) == :valid and
      Enum.any?(
        observations,
        &(Resolver.identity(&1.target_snapshot) != Resolver.identity(approved.target_snapshot))
      )
  end

  defp same_approval?(nil, _target), do: false
  defp same_approval?(approved, target), do: approved.target_snapshot == target

  defp count_actions(actions) do
    Enum.reduce(actions, %{additions: 0, existing: 0, held: 0, conflicts: 0}, fn action, counts ->
      Map.update!(counts, action, &(&1 + 1))
    end)
  end

  defp persist_rows(plan, actor) do
    {:ok, roster} = State.roster(plan.schedule_id)
    counts = %{approved: 0, unchanged: 0}

    Enum.reduce(plan.rows, counts, fn row, counts ->
      {:ok, key} = Key.normalize(plan.namespace, row.source_key)

      member =
        Enum.find(
          roster,
          &(&1.position_code == row.position_code and &1.name == row.expected_name)
        )

      current = current_mapping(plan, key.lookup_key)

      if current && current.target_snapshot == State.snapshot(member) do
        Map.update!(counts, :unchanged, &(&1 + 1))
      else
        append_approval(plan, row, key, member, actor, current)
        Map.update!(counts, :approved, &(&1 + 1))
      end
    end)
  end

  defp current_mapping(plan, lookup_key) do
    Mapping
    |> where(
      [m],
      m.scope_schedule_id == ^plan.schedule_id and m.namespace == ^to_string(plan.namespace)
    )
    |> where([m], m.lookup_key == ^lookup_key and m.current and m.status == "approved")
    |> lock("FOR UPDATE")
    |> Repo.one()
  end

  defp append_approval(plan, row, key, member, actor, current) do
    if current,
      do: Mapping |> where([m], m.id == ^current.id) |> Repo.update_all(set: [current: false])

    Repo.insert!(%Mapping{
      scope_schedule_id: plan.schedule_id,
      schedule_id: plan.schedule_id,
      schedule_resident_id: member.id,
      namespace: to_string(plan.namespace),
      source_key: row.source_key,
      lookup_key: key.lookup_key,
      normalization_version: key.normalization_version,
      target_snapshot: State.snapshot(member),
      revision: State.next_revision(plan.schedule_id, plan.namespace, key.lookup_key),
      status: "approved",
      current: true,
      evidence_origin: "reviewed_crosswalk",
      approved_by_id: actor.id,
      actor_snapshot: %{"user_id" => actor.id}
    })
  end

  defp digest(plan) do
    plan
    |> Map.take([:version, :schedule_id, :namespace, :rows, :state, :summary])
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
  end
end
