defmodule ResidencySchedule.Assistant.SharedShiftMatrix do
  @moduledoc """
  Pairwise shared-shift counting for a whole schedule in one pass. Every
  resident's effective segments are expanded into `{date, rotation_type}`
  cells; residents sharing a cell share a shift that day.
  """

  alias ResidencySchedule.Rotations

  @doc """
  Expands effective segments into shared-service day cells for one resident:
  covered days are skipped (someone else works them) and solo or off
  rotations never produce a cell.

      iex> segments = [
      ...>   %{rotation_type: "oncology", start_date: ~D[2026-07-06], end_date: ~D[2026-07-07], covered_by: nil},
      ...>   %{rotation_type: "float", start_date: ~D[2026-07-08], end_date: ~D[2026-07-08], covered_by: nil},
      ...>   %{rotation_type: "oncology", start_date: ~D[2026-07-09], end_date: ~D[2026-07-09], covered_by: %{id: 9}}
      ...> ]
      iex> ResidencySchedule.Assistant.SharedShiftMatrix.cells(segments)
      [{~D[2026-07-06], "oncology"}, {~D[2026-07-07], "oncology"}]
  """
  def cells(segments) do
    segments
    |> Enum.reject(&(&1.covered_by != nil or not Rotations.shared_service?(&1.rotation_type)))
    |> Enum.flat_map(fn seg ->
      seg.start_date |> Date.range(seg.end_date) |> Enum.map(&{&1, seg.rotation_type})
    end)
  end

  @doc """
  Counts shared days for every pair of residents. `cells_by_resident` maps a
  resident id to its cells (see `cells/1`). Returns `%{{a, b} => %{count, by_rotation}}`
  with `a < b`; pairs that never share a cell are absent.

      iex> cells = %{
      ...>   1 => [{~D[2026-07-06], "oncology"}, {~D[2026-07-07], "oncology"}],
      ...>   2 => [{~D[2026-07-06], "oncology"}, {~D[2026-07-07], "night_float"}],
      ...>   3 => [{~D[2026-07-06], "oncology"}]
      ...> }
      iex> counts = ResidencySchedule.Assistant.SharedShiftMatrix.pair_counts(cells)
      iex> counts[{1, 2}]
      %{count: 1, by_rotation: %{"oncology" => 1}}
      iex> Map.keys(counts) |> Enum.sort()
      [{1, 2}, {1, 3}, {2, 3}]
  """
  def pair_counts(cells_by_resident) do
    cells_by_resident
    |> residents_by_cell()
    |> Enum.reduce(%{}, fn {{_date, rotation_type}, residents}, acc ->
      residents
      |> pairs()
      |> Enum.reduce(acc, &add_shared_day(&2, &1, rotation_type))
    end)
  end

  @doc """
  Looks up a pair regardless of argument order, returning zero counts when
  the pair never shares a shift.

      iex> counts = %{{1, 2} => %{count: 3, by_rotation: %{"oncology" => 3}}}
      iex> ResidencySchedule.Assistant.SharedShiftMatrix.lookup(counts, 2, 1).count
      3

      iex> ResidencySchedule.Assistant.SharedShiftMatrix.lookup(%{}, 1, 2)
      %{count: 0, by_rotation: %{}}
  """
  def lookup(counts, a, b) do
    Map.get(counts, {min(a, b), max(a, b)}, %{count: 0, by_rotation: %{}})
  end

  defp residents_by_cell(cells_by_resident) do
    cells_by_resident
    |> Enum.flat_map(fn {id, cells} -> Enum.map(cells, &{&1, id}) end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  defp pairs(residents) do
    sorted = Enum.sort(residents)
    for a <- sorted, b <- sorted, a < b, do: {a, b}
  end

  defp add_shared_day(acc, pair, rotation_type) do
    Map.update(
      acc,
      pair,
      %{count: 1, by_rotation: %{rotation_type => 1}},
      fn %{count: count, by_rotation: by_rotation} ->
        %{count: count + 1, by_rotation: Map.update(by_rotation, rotation_type, 1, &(&1 + 1))}
      end
    )
  end
end
