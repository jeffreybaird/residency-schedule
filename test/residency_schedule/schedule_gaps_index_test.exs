defmodule ResidencySchedule.ScheduleGapsIndexTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Rotations.ScheduleGaps
  alias ResidencySchedule.ScheduleGapsReference

  test "inclusive, reversed, overlapping, adjacent and disjoint base and coverage ranges preserve full output" do
    bases = [
      rotation(1, 1, 10, 8),
      rotation(2, 1, 0, 2),
      rotation(3, 1, 2, 4),
      rotation(4, 1, 5, 5),
      rotation(5, 2, 0, 12)
    ]

    overrides = [coverage(1, 7, 6), coverage(1, 15, 17), coverage(1, 17, 18)]

    activities =
      for resident <- [1, 2, 3],
          date <- -1..19,
          do: activity(resident, date, "Unknown literal task")

    projected = equivalent(bases, activities, overrides)

    added_dates =
      projected
      |> Enum.filter(&(&1.id == nil and &1.schedule_resident_id == 1))
      |> Enum.map(&Date.diff(&1.start_date, day(0)))

    assert added_dates == [-1, 11, 12, 13, 14, 19]
    assert Enum.count(projected, &(&1.id == nil and &1.schedule_resident_id == 3)) == 21
  end

  test "same-day task grouping preserves original task order, loaded resident and chronological sort" do
    first = %{id: 9, name: "First loaded resident"}

    activities = [
      activity(9, 3, "Literal B"),
      %{activity(9, 1, "Literal B") | schedule_resident: first},
      activity(9, 1, "Literal A"),
      activity(9, 1, "Literal B"),
      activity(9, 1, "Vacation"),
      activity(8, 1, "Literal C")
    ]

    actual = equivalent([], activities, [])

    literal =
      Enum.find(
        actual,
        &(&1.schedule_resident_id == 9 and &1.start_date == day(1) and
            &1.rotation_type == "qgenda_assignment")
      )

    assert literal.source_tasks == ["Literal B", "Literal A"]
    assert literal.schedule_resident == first
    assert Enum.all?(actual, &is_nil(&1.id))
    assert equivalent([], [], []) == []
  end

  test "deterministic generated residents, intervals and tasks match the legacy projection exactly" do
    for seed <- 1..30 do
      :rand.seed(:exsss, {seed, seed + 1, seed + 2})

      rotations =
        for id <- 1..25, do: rotation(id, :rand.uniform(3), :rand.uniform(40), :rand.uniform(40))

      overrides =
        for _ <- 1..15, do: coverage(:rand.uniform(4), :rand.uniform(40), :rand.uniform(40))

      activities =
        for _ <- 1..100,
            do:
              activity(
                :rand.uniform(5),
                :rand.uniform(50),
                Enum.at(["Vacation", "Unknown task", "HH Nights 3rd Call"], :rand.uniform(3) - 1)
              )

      equivalent(rotations, activities, overrides)
    end
  end

  test "centuries-long occupied ranges retain boundaries without expanding calendar dates" do
    rotation = %{rotation(1, 1, 0, 1) | start_date: ~D[0001-01-01], end_date: ~D[9999-12-31]}
    assert equivalent([rotation], [activity(1, 0, "Literal task")], []) == [rotation]
  end

  test "doubling sparse intervals and activities grows below quadratic reductions" do
    small = sparse(512)
    large = sparse(1024)
    ScheduleGaps.project(elem(small, 0), elem(small, 1), [])
    small_work = reductions(small)
    large_work = reductions(large)

    assert large_work < small_work * 3,
           "expected indexed growth, got #{small_work} -> #{large_work} reductions"
  end

  defp equivalent(rotations, activities, overrides) do
    inputs = :erlang.term_to_binary({rotations, activities, overrides})
    actual = ScheduleGaps.project(rotations, activities, overrides)
    assert actual == ScheduleGapsReference.project(rotations, activities, overrides)
    assert :erlang.term_to_binary({rotations, activities, overrides}) == inputs
    actual
  end

  defp sparse(count) do
    rotations = for index <- 0..(count - 1), do: rotation(index + 1, 1, index * 2, index * 2)
    activities = for index <- 0..(count - 1), do: activity(1, index * 2 + 1, "Literal task")
    {rotations, activities}
  end

  defp reductions({rotations, activities}) do
    {:reductions, before_count} = Process.info(self(), :reductions)
    result = ScheduleGaps.project(rotations, activities, [])
    {:reductions, after_count} = Process.info(self(), :reductions)
    assert length(result) == length(rotations) + length(activities)
    after_count - before_count
  end

  defp rotation(id, resident, first, last),
    do: %{
      id: id,
      schedule_resident_id: resident,
      start_date: day(first),
      end_date: day(last),
      rotation_type: "oncology",
      opaque: {:preserve, id}
    }

  defp coverage(resident, first, last),
    do: %{
      covering_schedule_resident_id: resident,
      override_start_date: day(first),
      override_end_date: day(last)
    }

  defp activity(resident, offset, task),
    do: %{
      schedule_resident_id: resident,
      schedule_resident: %{id: resident},
      date: day(offset),
      raw_task: task
    }

  defp day(offset), do: Date.add(~D[2026-07-01], offset)
end
