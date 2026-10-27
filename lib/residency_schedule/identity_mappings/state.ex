defmodule ResidencySchedule.IdentityMappings.State do
  @moduledoc false
  import Ecto.Query

  alias ResidencySchedule.Accounts.User
  alias ResidencySchedule.IdentityMappings.Mapping
  alias ResidencySchedule.{Repo, Residents, Schedules}

  @doc "Checks persisted access. Database operation covered by integration tests."
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

  @doc "Reads the selected schedule roster. Database integration tested."
  def roster(id) when is_integer(id) and id > 0 do
    case Repo.get(Schedules.Schedule, id) do
      nil -> {:error, :not_found}
      _ -> {:ok, Residents.list_residents_for_schedule(id)}
    end
  end

  def roster(_id), do: {:error, :not_found}

  @doc "Reads immutable lookup scope, including retired targets. Database integration tested."
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

  @doc "Checks a saved target against actual roster state. Database integration tested."
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

  @doc "Builds review state tokens. Database integration tested through crosswalk approvals."
  def review_state(roster, mappings) do
    %{
      roster: roster |> Enum.map(&snapshot/1) |> Enum.sort_by(& &1["schedule_resident_id"]),
      mappings: Enum.map(mappings, &Map.take(&1, mapping_fields()))
    }
  end

  @doc "Allocates the next append-only revision. Database integration tested."
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
