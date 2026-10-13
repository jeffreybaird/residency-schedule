defmodule ResidencySchedule.ScheduleWindow do
  @moduledoc """
  A bounded presentation slice of the complete schedule grid.

  Every slot occupies 80 pixels. Clipping changes column spans only; original
  rotation identities and detail dates remain intact.
  """

  @doc """
  Selects the initial forty-column window with eight columns before today.

      iex> slots = for i <- 0..59, do: {1, i, Date.add(~D[2026-07-01], i), Date.add(~D[2026-07-01], i), i == 0}
      iex> ResidencySchedule.ScheduleWindow.initial_start(slots, ~D[2026-07-20])
      11
  """
  def initial_start(slots, today) do
    index =
      Enum.find_index(slots, fn {_, _, first, last, _} ->
        Date.compare(first, today) != :gt and Date.compare(last, today) != :lt
      end)

    min(max((index || 0) - 8, 0), max(length(slots) - 40, 0))
  end

  @doc """
  Clips grouped rows to a normalized half-open column range, capped at 128 slots.

      iex> slots = for i <- 0..9, do: {1, i, ~D[2026-07-01], ~D[2026-07-07], i == 0}
      iex> groups = [{2028, [%{cells: [{10, %{cell_id: "original"}}]}]}]
      iex> window = ResidencySchedule.ScheduleWindow.build(slots, groups, 2, 4)
      iex> {window.left_px, window.right_px, window.groups}
      {160, 320, [{2028, [%{cells: [{4, %{cell_id: "original"}}]}]}]}
  """
  def build(slots, groups, start, count) do
    total = length(slots)
    count = min(max(count, 1), min(total, 128))
    start = min(max(start, 0), total - count)
    finish = start + count

    %{
      start: start,
      count: count,
      finish: finish,
      total: total,
      left_px: start * 80,
      right_px: (total - finish) * 80,
      slots: Enum.slice(slots, start, count),
      groups: clip_groups(groups, start, finish)
    }
  end

  defp clip_groups(groups, start, finish) do
    Enum.map(groups, fn {year, residents} ->
      {year, Enum.map(residents, &%{&1 | cells: clip_cells(&1.cells, start, finish)})}
    end)
  end

  defp clip_cells(cells, start, finish) do
    {clipped, _} =
      Enum.reduce(cells, {[], 0}, fn {count, rotation}, {acc, offset} ->
        overlap = min(offset + count, finish) - max(offset, start)
        acc = if overlap > 0, do: [{overlap, rotation} | acc], else: acc
        {acc, offset + count}
      end)

    Enum.reverse(clipped)
  end
end
