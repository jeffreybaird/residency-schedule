defmodule ResidencySchedule.ScheduleGapsReference do
  @moduledoc false
  alias ResidencySchedule.DetailedSchedules.TaskEquivalence
  alias ResidencySchedule.Rotations.Rotation

  # Frozen pre-index algorithm: independent oracle for full output equivalence.
  def project(rotations, activities, overrides) do
    bases = Enum.group_by(rotations, & &1.schedule_resident_id)
    coverage = Enum.group_by(overrides, & &1.covering_schedule_resident_id)

    added =
      activities
      |> Enum.reject(fn activity ->
        Enum.any?(
          Map.get(bases, activity.schedule_resident_id, []),
          &(activity.date in Date.range(&1.start_date, &1.end_date))
        ) or
          Enum.any?(
            Map.get(coverage, activity.schedule_resident_id, []),
            &(activity.date in Date.range(&1.override_start_date, &1.override_end_date))
          )
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
end
