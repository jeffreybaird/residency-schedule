defmodule ResidencySchedule.Rotations.FridayNightFloat do
  @moduledoc "Derives Friday Strong night duty from literal imported assignments."

  alias ResidencySchedule.DetailedSchedules.TaskEquivalence

  @contact_nights for rank <- ~w(1st 2nd 3rd 4th),
                      do: "SMH Obstetrics Resident #{rank} Contact Night"

  @doc """
  Projects complete schedule inputs without changing their stored records.
  Approved coverage and explicit Strong night assignments take precedence.

      iex> alias ResidencySchedule.Rotations.{FridayNightFloat, Rotation}
      iex> alias ResidencySchedule.Residents.ScheduleResident
      iex> person = %ScheduleResident{id: 1, schedule_id: 7}
      iex> rotation = %Rotation{id: 2, schedule_resident_id: 1, schedule_resident: person, rotation_type: "ambulatory", start_date: ~D[2026-10-08], end_date: ~D[2026-10-10]}
      iex> activity = %{schedule_resident_id: 1, date: ~D[2026-10-09], raw_task: "SMH Obstetrics Resident 1st Contact Night"}
      iex> FridayNightFloat.project([rotation], [activity], []) |> Enum.map(&{&1.rotation_type, &1.start_date})
      [{"ambulatory", ~D[2026-10-08]}, {"night_float", ~D[2026-10-09]}, {"ambulatory", ~D[2026-10-10]}]
  """
  def project(rotations, activities, overrides) do
    protected = protected_dates(rotations, overrides)
    by_day = Enum.group_by(activities, &{&1.schedule_resident_id, &1.date})
    triggers = trigger_dates(rotations, by_day, protected)

    Enum.flat_map(rotations, &project_rotation(&1, by_day, triggers, protected))
  end

  defp protected_dates(rotations, overrides) do
    owners = Map.new(rotations, &{&1.id, &1.schedule_resident_id})

    overrides
    |> Enum.flat_map(fn override ->
      for date <- Date.range(override.override_start_date, override.override_end_date),
          resident <- [
            Map.get(owners, override.rotation_id),
            override.covering_schedule_resident_id
          ],
          not is_nil(resident),
          do: {resident, date}
    end)
    |> MapSet.new()
  end

  defp trigger_dates(rotations, by_day, protected) do
    rotations
    |> Enum.filter(&(&1.rotation_type == "ambulatory"))
    |> Enum.flat_map(fn rotation ->
      rotation.start_date
      |> Date.range(rotation.end_date)
      |> Enum.filter(&contact_night?(rotation, &1, by_day, protected))
      |> Enum.map(&{rotation.schedule_resident.schedule_id, &1})
    end)
    |> MapSet.new()
  end

  defp contact_night?(rotation, date, by_day, protected) do
    key = {rotation.schedule_resident_id, date}

    Date.day_of_week(date) == 5 and not MapSet.member?(protected, key) and
      Enum.any?(Map.get(by_day, key, []), &(&1.raw_task in @contact_nights))
  end

  defp project_rotation(rotation, by_day, triggers, protected) do
    rotation.start_date
    |> Date.range(rotation.end_date)
    |> Enum.chunk_by(&projected_type(rotation, &1, by_day, triggers, protected))
    |> Enum.map(fn dates ->
      first = hd(dates)
      type = projected_type(rotation, first, by_day, triggers, protected)

      %{
        rotation
        | start_date: first,
          end_date: List.last(dates),
          rotation_type: type,
          source_assignment_date:
            if(rotation.rotation_type == "ambulatory" and type == "night_float", do: first)
      }
    end)
  end

  defp projected_type(rotation, date, by_day, triggers, protected) do
    key = {rotation.schedule_resident_id, date}

    cond do
      MapSet.member?(protected, key) ->
        rotation.rotation_type

      rotation.rotation_type == "ambulatory" and contact_night?(rotation, date, by_day, protected) ->
        "night_float"

      rotation.rotation_type == "night_float" and
        MapSet.member?(triggers, {rotation.schedule_resident.schedule_id, date}) and
          not explicit_strong_night?(Map.get(by_day, key, [])) ->
        "post_call"

      true ->
        rotation.rotation_type
    end
  end

  defp explicit_strong_night?(activities) do
    Enum.any?(activities, fn activity ->
      TaskEquivalence.matches_rotation?(activity.raw_task, "night_float") or
        TaskEquivalence.matches_rotation?(activity.raw_task, "strong_weekend_nights")
    end)
  end
end
