defmodule ResidencySchedule.ScheduleEditor do
  @moduledoc """
  Edits individual dated assignments while preserving unrelated schedule records.
  Loaded snapshots detect concurrent changes before an atomic save.
  """
  import Ecto.Query

  alias ResidencySchedule.ChangeRequests.ChangeRequest
  alias ResidencySchedule.Repo
  alias ResidencySchedule.Residents.ScheduleResident
  alias ResidencySchedule.Rotations
  alias ResidencySchedule.Rotations.Rotation
  alias ResidencySchedule.Schedules.Schedule
  alias ResidencySchedule.ShiftOverrides.ShiftOverride

  @assignment_fields [:rotation_type, :start_date, :end_date]

  @doc "Loads every assignment at its saved dates. Exempt from doctest — database access."
  def load(id) when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807 do
    Repo.transaction(fn -> read_state(id, "FOR SHARE") end)
  end

  def load(_id), do: {:error, "Select an existing schedule"}

  @doc "Applies explicit assignment operations atomically. Exempt from doctest — database access."
  def commit(%{schedule_id: id, snapshot: snapshot} = state, operations)
      when is_integer(id) and id > 0 and id <= 9_223_372_036_854_775_807 and is_list(operations) do
    Repo.transaction(fn ->
      current = read_state(id, "FOR UPDATE")

      if current.snapshot != snapshot,
        do: Repo.rollback("Schedule changed since it was loaded. Reload before saving.")

      with :ok <- unique_operations(operations),
           {:ok, normalized} <- normalize_operations(current, operations),
           :ok <- protect_references(normalized) do
        Enum.each(normalized, &apply_operation/1)
        # Reload inside this transaction so the next edit uses the committed baseline.
        read_state(state.schedule_id, "FOR UPDATE")
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  def commit(_state, _operations), do: {:error, "Invalid schedule changes"}

  @doc """
  Validates assignment form values against the loaded schedule's date window.

      iex> state = %{academic_year: 2026, rotations: []}
      iex> {:ok, attrs} = ResidencySchedule.ScheduleEditor.validate_assignment(state, %{rotation_type: "ambulatory", start_date: "2026-12-14", end_date: "2026-12-18"})
      iex> attrs.start_date
      ~D[2026-12-14]
  """
  def validate_assignment(state, attrs) when is_map(attrs) do
    with {:ok, attrs} <- permitted_attrs(attrs),
         {:ok, start_date} <- parse_date(Map.get(attrs, :start_date)),
         {:ok, end_date} <- parse_date(Map.get(attrs, :end_date)),
         true <- Map.get(attrs, :rotation_type) in Rotations.all_rotation_types(),
         true <- valid_dates?(state, start_date, end_date) do
      {:ok, %{rotation_type: attrs.rotation_type, start_date: start_date, end_date: end_date}}
    else
      _ -> {:error, "Choose a valid rotation and ordered dates within this schedule's date range"}
    end
  end

  def validate_assignment(_state, _attrs), do: {:error, "Invalid assignment"}

  defp read_state(id, lock) do
    schedule = from(s in Schedule, where: s.id == ^id) |> locked_query(lock) |> Repo.one()
    if is_nil(schedule), do: Repo.rollback("Schedule no longer exists")

    residents =
      from(sr in ScheduleResident,
        where: sr.schedule_id == ^id,
        order_by: sr.id
      )
      |> locked_query(lock)
      |> Repo.all()

    resident_ids = Enum.map(residents, & &1.id)

    rotations =
      from(r in Rotation,
        where: r.schedule_resident_id in ^resident_ids,
        order_by: r.id
      )
      |> locked_query(lock)
      |> Repo.all()

    %{
      schedule_id: id,
      academic_year: schedule.academic_year,
      label: schedule.label,
      residents: Enum.map(Repo.preload(residents, :resident), &%{&1 | name: &1.resident.name}),
      rotations: rotations,
      snapshot: %{
        schedule: fields(schedule),
        residents: Enum.map(residents, &fields/1),
        rotations: Enum.map(rotations, &fields/1)
      }
    }
  end

  defp fields(%schema{} = record), do: Map.take(record, schema.__schema__(:fields))

  defp locked_query(query, "FOR SHARE"), do: lock(query, "FOR SHARE")
  defp locked_query(query, "FOR UPDATE"), do: lock(query, "FOR UPDATE")

  defp unique_operations(operations) do
    ids =
      Enum.flat_map(operations, fn
        %{action: action, rotation_id: id} when action in [:update, :delete] -> [id]
        _ -> []
      end)

    if length(ids) == length(Enum.uniq(ids)),
      do: :ok,
      else: {:error, "Each saved assignment can be changed only once per save"}
  end

  defp normalize_operations(state, operations) do
    Enum.reduce_while(operations, {:ok, []}, fn operation, {:ok, normalized} ->
      case normalize_operation(state, operation) do
        {:ok, result} -> {:cont, {:ok, normalized ++ List.wrap(result)}}
        error -> {:halt, error}
      end
    end)
  end

  defp normalize_operation(state, %{action: :add, schedule_resident_id: id, attrs: attrs}) do
    with true <- Enum.any?(state.residents, &(&1.id == id)),
         {:ok, attrs} <- validate_assignment(state, attrs) do
      {:ok, {:add, id, attrs}}
    else
      _ -> {:error, "Invalid resident or assignment"}
    end
  end

  defp normalize_operation(state, %{action: :update, rotation_id: id, attrs: attrs}) do
    with %Rotation{} = rotation <- find_rotation(state, id),
         {:ok, permitted} <- permitted_attrs(attrs),
         {:ok, updated} <-
           validate_assignment(
             state,
             Map.merge(Map.take(rotation, @assignment_fields), permitted)
           ) do
      if Map.take(rotation, @assignment_fields) == updated,
        do: {:ok, nil},
        else: {:ok, {:update, rotation, updated}}
    else
      _ -> {:error, "Invalid assignment update"}
    end
  end

  defp normalize_operation(state, %{action: :delete, rotation_id: id}) do
    case find_rotation(state, id) do
      %Rotation{} = rotation -> {:ok, {:delete, rotation}}
      _ -> {:error, "Assignment does not belong to this schedule"}
    end
  end

  defp normalize_operation(_state, _operation), do: {:error, "Invalid assignment operation"}

  defp find_rotation(state, id) when is_integer(id) and id > 0,
    do: Enum.find(state.rotations, &(&1.id == id))

  defp find_rotation(_state, _id), do: nil

  defp permitted_attrs(attrs) when is_map(attrs) do
    Enum.reduce_while(attrs, {:ok, %{}}, fn {key, value}, {:ok, result} ->
      case assignment_key(key) do
        nil -> {:halt, {:error, "Only rotation type and dates can be changed"}}
        field -> {:cont, {:ok, Map.put(result, field, value)}}
      end
    end)
  end

  defp permitted_attrs(_attrs), do: {:error, "Invalid assignment values"}
  defp assignment_key(key) when key in @assignment_fields, do: key
  defp assignment_key("rotation_type"), do: :rotation_type
  defp assignment_key("start_date"), do: :start_date
  defp assignment_key("end_date"), do: :end_date
  defp assignment_key(_key), do: nil

  defp parse_date(%Date{} = date), do: {:ok, date}
  defp parse_date(date) when is_binary(date), do: Date.from_iso8601(date)
  defp parse_date(_date), do: {:error, :invalid_date}

  defp valid_dates?(state, start_date, end_date) do
    first =
      Enum.min(
        [Date.new!(state.academic_year, 7, 1) | Enum.map(state.rotations, & &1.start_date)],
        Date
      )

    last =
      Enum.max(
        [Date.new!(state.academic_year + 1, 6, 30) | Enum.map(state.rotations, & &1.end_date)],
        Date
      )

    Date.compare(start_date, end_date) != :gt and Date.compare(start_date, first) != :lt and
      Date.compare(end_date, last) != :gt
  end

  defp protect_references(operations) do
    ids = Enum.flat_map(operations, &touched_ids/1)

    if Repo.exists?(from c in ChangeRequest, where: c.rotation_id in ^ids) or
         Repo.exists?(from o in ShiftOverride, where: o.rotation_id in ^ids),
       do:
         {:error,
          "Assignment has a coverage request or override; its coverage history must be resolved before editing"},
       else: :ok
  end

  defp touched_ids({:add, _id, _attrs}), do: []
  defp touched_ids({:update, rotation, _attrs}), do: [rotation.id]
  defp touched_ids({:delete, rotation}), do: [rotation.id]

  defp apply_operation({:add, id, attrs}) do
    %Rotation{}
    |> Rotation.changeset(Map.merge(attrs, %{schedule_resident_id: id, slot_index: -1}))
    |> persist(:insert)
  end

  defp apply_operation({:update, rotation, attrs}),
    do: rotation |> Rotation.changeset(attrs) |> persist(:update)

  defp apply_operation({:delete, rotation}), do: Repo.delete!(rotation)

  defp persist(changeset, action) do
    case apply(Repo, action, [changeset]) do
      {:ok, row} -> row
      {:error, _changeset} -> Repo.rollback("Assignment could not be saved")
    end
  end
end
