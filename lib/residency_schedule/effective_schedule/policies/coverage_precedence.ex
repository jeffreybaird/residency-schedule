defmodule ResidencySchedule.EffectiveSchedule.Policies.CoveragePrecedence do
  @moduledoc "Version 1 approved coverage precedence and calendar identity preservation."

  @doc """
  Converts projected blocks to effective segments, retaining uncovered work.

      iex> r = %{id: 1, schedule_resident_id: 2, rotation_type: "elective", start_date: ~D[2026-11-03], end_date: ~D[2026-11-03], slot_index: 0, source_assignment_date: nil, source_tasks: []}
      iex> [segment] = ResidencySchedule.EffectiveSchedule.Policies.CoveragePrecedence.apply([r], [])
      iex> {segment.rotation_type, segment.is_coverage, segment.covered_by}
      {"elective", false, nil}
  """
  def apply(rotations, overrides) do
    incoming = Enum.group_by(overrides, & &1.covering_schedule_resident_id)
    outgoing = Enum.group_by(overrides, & &1.rotation.schedule_resident_id)
    projected = Enum.group_by(rotations, & &1.id)

    own =
      Enum.flat_map(rotations, fn r ->
        cover = Map.get(incoming, r.schedule_resident_id, [])
        owner = Map.get(outgoing, r.schedule_resident_id, [])

        r.start_date
        |> Date.range(r.end_date)
        |> Enum.chunk_by(&day_state(&1, cover, owner))
        |> Enum.reject(&(day_state(hd(&1), cover, owner) == :elsewhere))
        |> Enum.map(fn days ->
          base(r)
          |> Map.merge(%{
            start_date: hd(days),
            end_date: List.last(days),
            covered_by: day_state(hd(days), cover, owner)
          })
        end)
      end)

    covered =
      Enum.flat_map(overrides, fn o ->
        o.override_start_date
        |> Date.range(o.override_end_date)
        |> Enum.chunk_by(&source(projected, o, &1))
        |> Enum.map(fn days ->
          {source_date, tasks} = source(projected, o, hd(days))

          %{
            rotation_type: o.rotation.rotation_type,
            schedule_resident_id: o.covering_schedule_resident_id,
            start_date: hd(days),
            end_date: List.last(days),
            calendar_start_date: o.override_start_date,
            source_assignment_date: source_date,
            source_tasks: tasks,
            slot_index: -1,
            is_coverage: true,
            covered_by: nil,
            original_resident: o.rotation.schedule_resident
          }
        end)
      end)

    Enum.sort_by(own ++ covered, & &1.start_date, Date)
  end

  defp base(r),
    do:
      r
      |> Map.take([
        :rotation_type,
        :schedule_resident_id,
        :start_date,
        :end_date,
        :slot_index,
        :source_assignment_date,
        :source_tasks
      ])
      |> Map.merge(%{is_coverage: false, covered_by: nil, original_resident: nil})

  defp day_state(day, incoming, outgoing) do
    cond do
      Enum.any?(incoming, &covers?(&1, day)) -> :elsewhere
      o = Enum.find(outgoing, &covers?(&1, day)) -> o.covering_schedule_resident
      true -> nil
    end
  end

  defp covers?(o, day), do: day in Date.range(o.override_start_date, o.override_end_date)

  defp source(projected, o, day) do
    r =
      projected
      |> Map.get(o.rotation_id, [])
      |> Enum.find(
        o.rotation,
        &(&1.rotation_type == o.rotation.rotation_type and
            day in Date.range(&1.start_date, &1.end_date))
      )

    {r.source_assignment_date, r.source_tasks}
  end
end
