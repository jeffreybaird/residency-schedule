defmodule ResidencySchedule.IdentityMappings.State do
  @moduledoc false
  import Ecto.Query

  alias ResidencySchedule.Accounts.User
  alias ResidencySchedule.IdentityMappings.Mapping
  alias ResidencySchedule.{Repo, Residents, Schedules}

  @doc """
  Checks the actor's current persisted administrator access.

      iex> ctx = ResidencySchedule.IdentityMappingDoctestFixtures.seed()
      iex> {:ok, actor} = ResidencySchedule.IdentityMappings.State.admin(ctx.admin)
      iex> {actor.id == ctx.admin.id, actor.role, actor.approved}
      {true, :admin, true}
  """
  def admin(user, lock \\ false)

  def admin(%{id: id}, lock) when is_integer(id) do
    query = from user in User, where: user.id == ^id
    query = if lock, do: lock(query, "FOR SHARE"), else: query

    case Repo.one(query) do
      %User{role: :admin, approved: true, denied: false} = user -> {:ok, user}
      _ -> {:error, :forbidden}
    end
  end

  def admin(_user, _lock), do: {:error, :forbidden}

  @doc """
  Reads memberships with the actual person names for the selected schedule.

      iex> ctx = ResidencySchedule.IdentityMappingDoctestFixtures.seed()
      iex> {:ok, roster} = ResidencySchedule.IdentityMappings.State.roster(ctx.schedule.id)
      iex> Enum.map(roster, &{&1.position_code, &1.name, &1.resident_id == ctx.member.resident_id})
      [{"R2-1", "Iris Reed", true}]
  """
  def roster(id) when is_integer(id) and id > 0 do
    case Repo.get(Schedules.Schedule, id) do
      nil -> {:error, :not_found}
      _ -> {:ok, Residents.list_residents_for_schedule(id)}
    end
  end

  def roster(_id), do: {:error, :not_found}

  @doc """
  Reads records by immutable lookup scope, including retired targets.

      iex> ctx = ResidencySchedule.IdentityMappingDoctestFixtures.seed()
      iex> {:ok, plan} = ResidencySchedule.IdentityMappings.prepare_crosswalk(ctx.schedule.id, :csv, ctx.rows, ctx.admin)
      iex> {:ok, _counts} = ResidencySchedule.IdentityMappings.approve_crosswalk(plan, ctx.admin)
      iex> records = ResidencySchedule.IdentityMappings.State.mappings(ctx.schedule.id, :csv)
      iex> Enum.map(records, &{&1.lookup_key, &1.status, &1.target_snapshot["resident_id"] == ctx.member.resident_id})
      [{"legacy iris", "approved", true}]
  """
  def mappings(schedule_id, namespace) do
    Mapping
    |> where([m], m.scope_schedule_id == ^schedule_id and m.namespace == ^to_string(namespace))
    |> order_by([m], m.id)
    |> Repo.all()
  end

  @doc """
  Captures the actual membership-derived person and roster identity.

      iex> ResidencySchedule.IdentityMappings.State.snapshot(%{schedule_id: 1, id: 2, resident_id: 3, position_code: "R2-1", name: "Iris Reed"})
      %{"schedule_id" => 1, "schedule_resident_id" => 2, "resident_id" => 3, "position_code" => "R2-1", "name" => "Iris Reed"}
  """
  def snapshot(member) do
    %{
      "schedule_id" => member.schedule_id,
      "schedule_resident_id" => member.id,
      "resident_id" => member.resident_id,
      "position_code" => member.position_code,
      "name" => member.name
    }
  end

  @doc """
  Checks a saved membership/person snapshot against actual roster state.

      iex> ctx = ResidencySchedule.IdentityMappingDoctestFixtures.seed()
      iex> {:ok, plan} = ResidencySchedule.IdentityMappings.prepare_crosswalk(ctx.schedule.id, :csv, ctx.rows, ctx.admin)
      iex> {:ok, _counts} = ResidencySchedule.IdentityMappings.approve_crosswalk(plan, ctx.admin)
      iex> [mapping] = ResidencySchedule.IdentityMappings.State.mappings(ctx.schedule.id, :csv)
      iex> {:ok, roster} = ResidencySchedule.IdentityMappings.State.roster(ctx.schedule.id)
      iex> ResidencySchedule.IdentityMappings.State.target_status(mapping, roster)
      :valid
  """
  def target_status(mapping, roster) do
    if is_nil(mapping.schedule_id) or is_nil(mapping.schedule_resident_id) do
      :target_unavailable
    else
      case Enum.find(roster, &(&1.id == mapping.schedule_resident_id)) do
        nil -> :target_unavailable
        member -> compare_target(mapping, member)
      end
    end
  end

  @doc """
  Captures roster and mapping state for detecting stale prepared reviews.

      iex> ctx = ResidencySchedule.IdentityMappingDoctestFixtures.seed()
      iex> {:ok, plan} = ResidencySchedule.IdentityMappings.prepare_crosswalk(ctx.schedule.id, :csv, ctx.rows, ctx.admin)
      iex> {:ok, _counts} = ResidencySchedule.IdentityMappings.approve_crosswalk(plan, ctx.admin)
      iex> {:ok, roster} = ResidencySchedule.IdentityMappings.State.roster(ctx.schedule.id)
      iex> records = ResidencySchedule.IdentityMappings.State.mappings(ctx.schedule.id, :csv)
      iex> state = ResidencySchedule.IdentityMappings.State.review_state(roster, records)
      iex> {state.roster == [ResidencySchedule.IdentityMappings.State.snapshot(ctx.member)], Enum.map(state.mappings, & &1.revision)}
      {true, [1]}
  """
  def review_state(roster, mappings) do
    %{
      roster: roster |> Enum.map(&snapshot/1) |> Enum.sort_by(& &1["schedule_resident_id"]),
      mappings: Enum.map(mappings, &Map.take(&1, mapping_fields()))
    }
  end

  @doc """
  Reads the next revision number after retained evidence for a scoped key.

      iex> ctx = ResidencySchedule.IdentityMappingDoctestFixtures.seed()
      iex> {:ok, plan} = ResidencySchedule.IdentityMappings.prepare_crosswalk(ctx.schedule.id, :csv, ctx.rows, ctx.admin)
      iex> {:ok, _counts} = ResidencySchedule.IdentityMappings.approve_crosswalk(plan, ctx.admin)
      iex> ResidencySchedule.IdentityMappings.State.next_revision(ctx.schedule.id, :csv, "legacy iris")
      2
  """
  def next_revision(schedule_id, namespace, lookup_key) do
    Mapping
    |> where([m], m.scope_schedule_id == ^schedule_id and m.namespace == ^to_string(namespace))
    |> where([m], m.lookup_key == ^lookup_key)
    |> select([m], max(m.revision))
    |> Repo.one()
    |> then(&((&1 || 0) + 1))
  end

  defp compare_target(mapping, member) do
    if mapping.scope_schedule_id == member.schedule_id and
         mapping.schedule_id == member.schedule_id and mapping.target_snapshot == snapshot(member),
       do: :valid,
       else: :target_changed
  end

  defp mapping_fields do
    ~w(id scope_schedule_id schedule_id schedule_resident_id namespace source_key lookup_key normalization_version target_snapshot revision status current evidence_origin evidence_source_id evidence_snapshot approved_by_id actor_snapshot)a
  end
end
