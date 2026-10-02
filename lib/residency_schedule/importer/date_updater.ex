defmodule ResidencySchedule.Importer.DateUpdater do
  @moduledoc """
  Applies dated assignments to existing schedule residents without replacing a year.
  Rotations backing coverage history are protected from deletion or splitting.
  """
  import Ecto.Query
  alias ResidencySchedule.ChangeRequests.ChangeRequest
  alias ResidencySchedule.Importer.ResidentLinker
  alias ResidencySchedule.Repo
  alias ResidencySchedule.Residents
  alias ResidencySchedule.Residents.ScheduleResident
  alias ResidencySchedule.Rotations.Rotation
  alias ResidencySchedule.Schedules
  alias ResidencySchedule.ShiftOverrides.ShiftOverride

  @doc """
  Validates a date update and returns locked identity proposals without writing.
  Exempt from doctest — hits the database.
  """
  def prepare(parsed, year) do
    with {:ok, schedule} <- target_schedule(year),
         {:ok, residents} <- target_residents(parsed, schedule.id),
         :ok <- validate_updates(parsed, year),
         :ok <- validate_references(parsed, residents) do
      proposals =
        Enum.map(parsed, fn row ->
          resident = Map.fetch!(residents, row.position_code)

          %ResidentLinker{
            position_code: row.position_code,
            name: resident.name,
            proposed_id: resident.resident_id,
            confidence: :exact
          }
        end)

      {:ok, %{schedule_id: schedule.id, proposals: proposals, date_range: update_range(parsed)}}
    end
  end

  @doc """
  Atomically patches existing rotations with confirmed, unchanged person links.
  Exempt from doctest — hits the database.
  """
  def commit(parsed, year, links) do
    Repo.transaction(fn ->
      schedule =
        case target_schedule(year) do
          {:ok, schedule} ->
            Repo.one!(
              from s in Schedules.Schedule, where: s.id == ^schedule.id, lock: "FOR UPDATE"
            )

          {:error, reason} ->
            Repo.rollback(reason)
        end

      with {:ok, residents} <- target_residents(parsed, schedule.id),
           :ok <- validate_updates(parsed, year),
           :ok <- validate_links(links, residents),
           :ok <- lock_update_rotations(parsed, residents),
           :ok <- validate_references(parsed, residents) do
        %{
          schedule_id: schedule.id,
          residents: length(parsed),
          rotations: apply_updates(parsed, residents)
        }
      else
        {:error, reason} -> Repo.rollback(reason)
      end
    end)
  end

  defp apply_updates(parsed, residents) do
    Enum.reduce(parsed, 0, fn row, count ->
      resident = Map.fetch!(residents, row.position_code)
      count + replace_dates(resident.id, row.date_updates)
    end)
  end

  defp target_schedule(year) when is_integer(year) and year in 1..9998 do
    case Schedules.get_by_year(year) do
      nil -> {:error, "Select an existing academic year for date updates"}
      schedule -> {:ok, schedule}
    end
  end

  defp target_schedule(_year), do: {:error, "Select an existing academic year for date updates"}

  defp target_residents([], _id), do: {:error, "No residents to update"}

  defp target_residents(parsed, id) do
    residents = id |> Residents.list_residents_for_schedule() |> Map.new(&{&1.position_code, &1})
    codes = Enum.map(parsed, & &1.position_code)

    cond do
      length(codes) != length(Enum.uniq(codes)) ->
        {:error, "Duplicate resident positions in update"}

      Enum.any?(codes, &(not Map.has_key?(residents, &1))) ->
        {:error, "Every update position must already exist in the selected schedule"}

      true ->
        {:ok, Map.take(residents, codes)}
    end
  end

  defp validate_updates(parsed, year) do
    first = Date.new!(year, 7, 1)
    last = Date.new!(year + 1, 6, 30)

    cond do
      Enum.all?(parsed, &(&1.date_updates == [])) ->
        {:error, "No recognized assignments or OFF cells to update"}

      Enum.any?(parsed, &(not valid_row_updates?(&1.date_updates, first, last))) ->
        {:error, "Invalid or overlapping dates in update"}

      true ->
        :ok
    end
  end

  defp valid_row_updates?(updates, first, last) do
    sorted = Enum.sort_by(updates, &Date.to_gregorian_days(&1.start_date))

    Enum.all?(sorted, fn update ->
      Date.compare(update.start_date, first) != :lt and Date.compare(update.end_date, last) != :gt and
        Date.compare(update.start_date, update.end_date) != :gt and valid_update_rotation?(update)
    end) and
      sorted
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.all?(fn [a, b] -> Date.compare(a.end_date, b.start_date) == :lt end)
  end

  defp valid_update_rotation?(%{rotation: nil}), do: true

  defp valid_update_rotation?(update) do
    rotation = update.rotation

    is_atom(rotation.rotation_type) and is_integer(rotation.slot_index) and
      Date.compare(rotation.start_date, update.start_date) != :lt and
      Date.compare(rotation.end_date, update.end_date) != :gt and
      Date.compare(rotation.start_date, rotation.end_date) != :gt
  end

  defp validate_links(links, residents) do
    if Enum.all?(residents, fn {code, resident} ->
         Map.get(links, code, resident.resident_id) == resident.resident_id
       end), do: :ok, else: {:error, "Date updates cannot change existing resident links"}
  end

  defp lock_update_rotations(parsed, residents) do
    ids = Enum.map(residents, fn {_, resident} -> resident.id end)

    Repo.all(
      from sr in ScheduleResident, where: sr.id in ^ids, order_by: sr.id, lock: "FOR UPDATE"
    )

    # A row lock also prevents a new FK reference from racing the dependency check.
    touched_ids(parsed, residents)
    |> then(fn ids ->
      Repo.all(from r in Rotation, where: r.id in ^ids, order_by: r.id, lock: "FOR UPDATE")
    end)

    :ok
  end

  defp validate_references(parsed, residents) do
    ids = touched_ids(parsed, residents)

    if Repo.exists?(from r in ChangeRequest, where: r.rotation_id in ^ids) or
         Repo.exists?(from o in ShiftOverride, where: o.rotation_id in ^ids),
       do:
         {:error,
          "Update touches a rotation with a coverage request or override; resolve its coverage history before updating"},
       else: :ok
  end

  defp touched_ids(parsed, residents) do
    Enum.flat_map(parsed, fn row ->
      residents[row.position_code].id
      |> existing_rotations()
      |> Enum.filter(fn rotation -> Enum.any?(row.date_updates, &overlap?(rotation, &1)) end)
      |> Enum.map(& &1.id)
    end)
  end

  defp existing_rotations(id),
    do: Repo.all(from r in Rotation, where: r.schedule_resident_id == ^id)

  defp overlap?(a, b),
    do:
      Date.compare(a.start_date, b.end_date) != :gt and
        Date.compare(a.end_date, b.start_date) != :lt

  defp replace_dates(id, updates) do
    id
    |> existing_rotations()
    |> Enum.filter(fn rotation -> Enum.any?(updates, &overlap?(rotation, &1)) end)
    |> Enum.each(fn rotation ->
      fragments =
        Enum.reduce(updates, [rotation], fn update, fragments ->
          Enum.flat_map(fragments, &subtract_range(&1, update))
        end)

      Repo.delete!(rotation)

      Enum.each(fragments, fn fragment ->
        insert_rotation(
          id,
          Map.take(fragment, [:rotation_type, :slot_index, :start_date, :end_date])
        )
      end)
    end)

    updates
    |> Enum.map(& &1.rotation)
    |> Enum.reject(&is_nil/1)
    |> Enum.each(fn rotation ->
      insert_rotation(id, %{rotation | rotation_type: Atom.to_string(rotation.rotation_type)})
    end)

    Enum.count(updates, &(not is_nil(&1.rotation)))
  end

  defp subtract_range(rotation, update) do
    if overlap?(rotation, update) do
      before =
        if Date.compare(rotation.start_date, update.start_date) == :lt,
          do: [%{rotation | end_date: Date.add(update.start_date, -1)}],
          else: []

      after_range =
        if Date.compare(rotation.end_date, update.end_date) == :gt,
          do: [%{rotation | start_date: Date.add(update.end_date, 1)}],
          else: []

      before ++ after_range
    else
      [rotation]
    end
  end

  defp insert_rotation(id, attrs) do
    # Negative indices mark literal dates for legacy editor reloads.
    attrs =
      Map.update!(attrs, :slot_index, fn index -> if index < 0, do: index, else: -index - 1 end)

    %Rotation{} |> Rotation.changeset(Map.put(attrs, :schedule_resident_id, id)) |> Repo.insert!()
  end

  defp update_range(parsed) do
    updates = Enum.flat_map(parsed, & &1.date_updates)

    {updates |> Enum.map(& &1.start_date) |> Enum.min(Date),
     updates |> Enum.map(& &1.end_date) |> Enum.max(Date)}
  end
end
