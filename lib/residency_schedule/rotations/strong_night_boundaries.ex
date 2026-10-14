defmodule ResidencySchedule.Rotations.StrongNightBoundaries do
  @moduledoc "Projects legacy Strong night slots onto the evening their duty starts."

  alias ResidencySchedule.DetailedSchedules.TaskEquivalence

  @doc """
  Aligns canonical Strong blocks while preserving dated duty and coverage evidence.

      iex> alias ResidencySchedule.Rotations.{Rotation, StrongNightBoundaries}
      iex> night = %Rotation{id: 1, schedule_resident_id: 2, rotation_type: "night_float", start_date: ~D[2026-11-02], end_date: ~D[2026-11-06]}
      iex> StrongNightBoundaries.project([night], [], []) |> Enum.map(&{&1.rotation_type, &1.start_date, &1.end_date})
      [{"night_float", ~D[2026-11-01], ~D[2026-11-05]}, {"post_call", ~D[2026-11-06], ~D[2026-11-06]}]
  """
  def project(rotations, activities, overrides) do
    by_start = Enum.group_by(rotations, &{&1.schedule_resident_id, &1.start_date})
    by_end = Enum.group_by(rotations, &{&1.schedule_resident_id, &1.end_date})
    protected = index_protected_dates(rotations, overrides)
    explicit = index_explicit_fridays(rotations, activities)
    post_call_dates = index_post_call_dates(rotations)

    rotations
    |> Enum.flat_map(&align_rotation(&1, by_start, by_end, explicit, post_call_dates))
    |> Enum.flat_map(&remove_displaced_dates(&1, protected, explicit))
    |> restore_protected_dates(protected)
    |> Enum.sort_by(& &1.start_date, Date)
  end

  defp canonical?(rotation, type, weekday, duration) do
    rotation.rotation_type == type and Date.day_of_week(rotation.start_date) == weekday and
      Date.diff(rotation.end_date, rotation.start_date) == duration
  end

  defp canonical_neighbor?(rotation, index, date, type, weekday, duration) do
    index
    |> Map.get({rotation.schedule_resident_id, date}, [])
    |> Enum.any?(&canonical?(&1, type, weekday, duration))
  end

  defp ambulatory_pair?(rotation, by_end) do
    canonical?(rotation, "strong_weekend_nights", 6, 1) and
      canonical_neighbor?(
        rotation,
        by_end,
        Date.add(rotation.start_date, -1),
        "ambulatory",
        1,
        4
      )
  end

  defp align_rotation(rotation, by_start, by_end, explicit, post_call_dates) do
    cond do
      canonical?(rotation, "night_float", 1, 4) ->
        align_night_float(rotation, by_start, explicit, post_call_dates)

      ambulatory_pair?(rotation, by_end) ->
        [shift_night(rotation)]

      canonical?(rotation, "ambulatory", 1, 4) and
          canonical_neighbor?(
            rotation,
            by_start,
            Date.add(rotation.end_date, 1),
            "strong_weekend_nights",
            6,
            1
          ) ->
        [%{rotation | end_date: Date.add(rotation.end_date, -1)}]

      canonical?(rotation, "post_call", 6, 1) and
          (canonical_neighbor?(
             rotation,
             by_end,
             Date.add(rotation.start_date, -1),
             "night_float",
             1,
             4
           ) or
             canonical_neighbor?(
               rotation,
               by_start,
               Date.add(rotation.end_date, 1),
               "night_float",
               1,
               4
             )) ->
        [shift_dates(rotation)]

      true ->
        [rotation]
    end
  end

  defp align_night_float(rotation, by_start, explicit, post_call_dates) do
    friday_key = {rotation.schedule_resident_id, rotation.end_date}

    tail =
      cond do
        MapSet.member?(explicit, friday_key) ->
          [
            %{
              rotation
              | start_date: rotation.end_date,
                source_assignment_date: rotation.end_date
            }
          ]

        MapSet.member?(post_call_dates, friday_key) or
            canonical_neighbor?(
              rotation,
              by_start,
              Date.add(rotation.end_date, 1),
              "post_call",
              6,
              1
            ) ->
          []

        true ->
          [%{rotation | start_date: rotation.end_date, rotation_type: "post_call"}]
      end

    [shift_night(rotation) | tail]
  end

  defp shift_dates(rotation),
    do: %{
      rotation
      | start_date: Date.add(rotation.start_date, -1),
        end_date: Date.add(rotation.end_date, -1)
    }

  defp shift_night(rotation) do
    rotation
    |> shift_dates()
    |> then(&%{&1 | source_assignment_date: &1.start_date})
  end

  defp index_explicit_fridays(rotations, activities) do
    fridays =
      rotations
      |> Enum.filter(&canonical?(&1, "night_float", 1, 4))
      |> MapSet.new(&{&1.schedule_resident_id, &1.end_date})

    activities
    |> Enum.filter(fn activity ->
      MapSet.member?(fridays, {activity.schedule_resident_id, activity.date}) and
        TaskEquivalence.matches_rotation?(activity.raw_task, "night_float")
    end)
    |> MapSet.new(&{&1.schedule_resident_id, &1.date})
  end

  defp index_post_call_dates(rotations) do
    rotations
    |> Enum.filter(&(&1.rotation_type == "post_call"))
    |> Enum.flat_map(fn rotation ->
      for date <- Date.range(rotation.start_date, rotation.end_date),
          do: {rotation.schedule_resident_id, date}
    end)
    |> MapSet.new()
  end

  defp index_protected_dates(rotations, overrides) do
    by_id = Map.new(rotations, &{&1.id, &1})

    overrides
    |> Enum.flat_map(fn override ->
      protected_rotation_dates(Map.get(by_id, override.rotation_id), override)
    end)
    |> Map.new()
  end

  defp protected_rotation_dates(nil, _override), do: []

  defp protected_rotation_dates(rotation, override) do
    for date <- Date.range(override.override_start_date, override.override_end_date),
        do: {{rotation.schedule_resident_id, date}, rotation}
  end

  defp remove_displaced_dates(rotation, protected, explicit) do
    rotation.start_date
    |> Date.range(rotation.end_date)
    |> Enum.chunk_by(&retained_date?(rotation, &1, protected, explicit))
    |> Enum.filter(&retained_date?(rotation, hd(&1), protected, explicit))
    |> Enum.map(&%{rotation | start_date: hd(&1), end_date: List.last(&1)})
  end

  defp retained_date?(rotation, date, protected, explicit) do
    key = {rotation.schedule_resident_id, date}

    case Map.get(protected, key) do
      nil ->
        rotation.rotation_type != "post_call" or not MapSet.member?(explicit, key)

      original ->
        original.id == rotation.id and original.rotation_type == rotation.rotation_type
    end
  end

  defp restore_protected_dates(rotations, protected) do
    present =
      rotations
      |> Enum.flat_map(fn rotation ->
        for date <- Date.range(rotation.start_date, rotation.end_date),
            do: {rotation.schedule_resident_id, date}
      end)
      |> MapSet.new()

    restored =
      protected
      |> Enum.reject(fn {key, _rotation} -> MapSet.member?(present, key) end)
      |> Enum.map(fn {{_resident_id, date}, rotation} ->
        %{rotation | start_date: date, end_date: date}
      end)

    rotations ++ restored
  end
end
