defmodule ResidencySchedule.ScheduleCellReference do
  @moduledoc """
  Frozen scan-and-sort cell builder from commit 680c023, used only as an
  independent regression oracle and benchmark comparison. Do not optimize it.
  """

  @doc false
  def groups(all_slots, rotation_lookup) do
    all_slots
    |> Enum.map(fn {schedule_id, idx, start, last, _first?} ->
      {schedule_id, start, last, lookup_slot_rotation(rotation_lookup, schedule_id, idx, start)}
    end)
    |> Enum.chunk_while([], &chunk_adjacent_cells/2, fn
      [] -> {:cont, []}
      group -> {:cont, Enum.reverse(group), []}
    end)
    |> Enum.map(fn group ->
      {schedule_id, first, _, rotation} = hd(group)
      {_, _, last, _} = List.last(group)
      {length(group), annotate_cell(rotation, schedule_id, first, last)}
    end)
  end

  defp chunk_adjacent_cells(cell, []), do: {:cont, [cell]}

  defp chunk_adjacent_cells({schedule_id, first, _, rotation} = cell, [previous | _] = group) do
    {previous_schedule, _, previous_last, previous_rotation} = previous

    if schedule_id == previous_schedule and first == Date.add(previous_last, 1) and
         rotation_cell_key(rotation) == rotation_cell_key(previous_rotation) do
      {:cont, [cell | group]}
    else
      {:cont, Enum.reverse(group), [cell]}
    end
  end

  defp lookup_slot_rotation(lookup, schedule_id, idx, date) do
    case Map.get(lookup, schedule_id) do
      nil ->
        Map.get(lookup, {schedule_id, idx})

      rotations ->
        rotations
        |> Enum.filter(
          &(Date.compare(&1.start_date, date) != :gt and Date.compare(&1.end_date, date) != :lt)
        )
        |> Enum.sort_by(& &1.rotation_type)
        |> combine_concurrent_rotations()
    end
  end

  defp annotate_cell(nil, _, _, _), do: nil

  defp annotate_cell(%{rotations: rotations} = cell, schedule_id, first, last) do
    %{
      cell
      | rotations: Enum.map(rotations, &annotate_cell(&1, schedule_id, first, last)),
        end_date: last
    }
  end

  defp annotate_cell(rotation, schedule_id, first, last) do
    token =
      {schedule_id, Map.get(rotation, :schedule_resident_id), Map.get(rotation, :id),
       rotation.rotation_type, Map.get(rotation, :source_tasks, []), first, last}
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    Map.merge(rotation, %{
      schedule_id: schedule_id,
      start_date: first,
      end_date: last,
      cell_id: token
    })
  end

  defp combine_concurrent_rotations([]), do: nil
  defp combine_concurrent_rotations([rotation]), do: rotation

  defp combine_concurrent_rotations(rotations) do
    %{rotations: rotations, end_date: rotations |> Enum.map(& &1.end_date) |> Enum.max(Date)}
  end

  defp rotation_cell_key(nil), do: :blank
  defp rotation_cell_key(%{rotations: rotations}), do: Enum.map(rotations, &rotation_cell_key/1)

  defp rotation_cell_key(rotation),
    do: {rotation.rotation_type, Map.get(rotation, :source_tasks, [])}
end
