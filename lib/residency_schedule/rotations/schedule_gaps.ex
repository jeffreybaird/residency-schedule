defmodule ResidencySchedule.Rotations.ScheduleGaps do
  @moduledoc "Fills display-only schedule gaps from literal imported assignments."

  alias ResidencySchedule.DetailedSchedules.TaskEquivalence
  alias ResidencySchedule.Rotations.Rotation

  @doc """
  Adds dated assignments only where neither a base rotation nor coverage exists.
  Activities carry their loaded schedule resident; no synthetic database ID is assigned.

      iex> resident = %{id: 7}
      iex> activity = %{schedule_resident_id: 7, schedule_resident: resident, date: ~D[2026-10-10], raw_task: "Vacation"}
      iex> [entry] = ResidencySchedule.Rotations.ScheduleGaps.project([], [activity], [])
      iex> {entry.rotation_type, entry.source_tasks, entry.id}
      {"vacation", ["Vacation"], nil}
  """
  def project(rotations, activities, overrides) do
    occupied = index_occupied_intervals(rotations, overrides)

    added =
      activities
      |> Enum.reject(fn activity ->
        intervals = Map.get(occupied, activity.schedule_resident_id, {})
        day = Date.to_gregorian_days(activity.date)
        occupied_day?(intervals, day, 0, tuple_size(intervals) - 1)
      end)
      |> Enum.group_by(
        &{&1.schedule_resident_id, &1.date, TaskEquivalence.gap_type(&1.raw_task, &1.date)}
      )
      |> Enum.map(fn {{resident_id, date, type}, tasks} ->
        %Rotation{
          schedule_resident_id: resident_id,
          schedule_resident: hd(tasks).schedule_resident,
          rotation_type: type,
          start_date: date,
          end_date: date,
          slot_index: -1,
          source_assignment_date: date,
          source_tasks: tasks |> Enum.map(& &1.raw_task) |> Enum.uniq()
        }
      end)

    Enum.sort_by(
      rotations ++ added,
      &{Date.to_gregorian_days(&1.start_date), &1.schedule_resident_id, &1.rotation_type}
    )
  end

  defp index_occupied_intervals(rotations, overrides) do
    bases =
      Enum.reduce(rotations, %{}, fn rotation, acc ->
        add_occupied_interval(
          acc,
          rotation.schedule_resident_id,
          rotation.start_date,
          rotation.end_date
        )
      end)

    overrides
    |> Enum.reduce(bases, fn override, acc ->
      add_occupied_interval(
        acc,
        override.covering_schedule_resident_id,
        override.override_start_date,
        override.override_end_date
      )
    end)
    |> Map.new(fn {resident_id, intervals} ->
      merged =
        intervals
        |> Enum.sort()
        |> Enum.reduce([], &merge_occupied_interval/2)
        |> Enum.reverse()
        |> List.to_tuple()

      {resident_id, merged}
    end)
  end

  defp add_occupied_interval(intervals, resident_id, first_date, last_date) do
    first = Date.to_gregorian_days(first_date)
    last = Date.to_gregorian_days(last_date)
    # Date.range/2 includes both endpoints even when the range runs backwards.
    interval = {min(first, last), max(first, last)}
    Map.update(intervals, resident_id, [interval], &[interval | &1])
  end

  defp merge_occupied_interval({first, last}, [{previous_first, previous_last} | rest])
       when first <= previous_last + 1,
       do: [{previous_first, max(previous_last, last)} | rest]

  defp merge_occupied_interval(interval, intervals), do: [interval | intervals]

  defp occupied_day?(_intervals, _day, low, high) when low > high, do: false

  defp occupied_day?(intervals, day, low, high) do
    middle = div(low + high, 2)
    {first, last} = elem(intervals, middle)

    cond do
      day < first -> occupied_day?(intervals, day, low, middle - 1)
      day > last -> occupied_day?(intervals, day, middle + 1, high)
      true -> true
    end
  end
end
