defmodule ResidencySchedule.ScheduleWindowTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.ScheduleWindow
  doctest ScheduleWindow

  test "initial range contains today with an eight-column lead and clamps at either end" do
    slots = slots(100)
    assert ScheduleWindow.initial_start(slots, ~D[2027-06-16]) == 42
    assert ScheduleWindow.initial_start(slots, ~D[2026-07-01]) == 0
    assert ScheduleWindow.initial_start(slots, ~D[2028-05-24]) == 60
    assert ScheduleWindow.initial_start(slots, ~D[2030-01-01]) == 0
    assert ScheduleWindow.initial_start(slots, ~D[2020-01-01]) == 0
    assert ScheduleWindow.initial_start([], ~D[2026-07-01]) == 0
  end

  test "clipping preserves original merged and stacked cell identities and full date details" do
    first = %{
      cell_id: "original-first",
      start_date: ~D[2026-07-01],
      end_date: ~D[2026-07-30],
      rotation_type: "clinic"
    }

    last = %{
      cell_id: "original-last",
      start_date: ~D[2026-08-01],
      end_date: ~D[2026-08-30],
      rotations: [%{cell_id: "stack-one"}, %{cell_id: "stack-two"}]
    }

    groups = [{2028, [%{id: 1, name: "Synthetic", cells: [{4, first}, {2, nil}, {4, last}]}]}]
    window = ScheduleWindow.build(slots(10), groups, 2, 6)
    assert window.start == 2
    assert window.finish == 8
    assert window.count == 6
    assert window.total == 10
    assert window.left_px == 160
    assert window.right_px == 160
    assert window.slots == Enum.slice(slots(10), 2, 6)

    assert window.groups == [
             {2028, [%{id: 1, name: "Synthetic", cells: [{2, first}, {2, nil}, {2, last}]}]}
           ]

    assert groups == [
             {2028, [%{id: 1, name: "Synthetic", cells: [{4, first}, {2, nil}, {4, last}]}]}
           ]
  end

  test "every bounded window is the exact intersection of the original row" do
    cells = [
      {7, %{cell_id: "a"}},
      {3, nil},
      {45, %{cell_id: "b"}},
      {1, %{cell_id: "c"}},
      {44, nil}
    ]

    expanded = Enum.flat_map(cells, fn {count, value} -> List.duplicate(value, count) end)
    groups = [{2028, [%{cells: cells}]}]

    for start <- [0, 1, 6, 7, 9, 10, 30, 54, 55, 56, 90, 99], count <- [1, 8, 40, 64] do
      window = ScheduleWindow.build(slots(100), groups, start, count)
      [{2028, [%{cells: clipped}]}] = window.groups
      actual = Enum.flat_map(clipped, fn {length, value} -> List.duplicate(value, length) end)
      assert actual == Enum.slice(expanded, window.start, window.count)
      assert Enum.all?(clipped, fn {length, _} -> length > 0 end)
      assert window.left_px + window.count * 80 + window.right_px == 100 * 80
      assert window.finish == window.start + window.count
    end
  end

  test "range bounds prevent unbounded columns and preserve complete small and empty grids" do
    groups = [{2028, [%{cells: [{200, nil}]}]}]

    assert %{start: 0, count: 128, finish: 128} =
             ScheduleWindow.build(slots(200), groups, -10, 100_000)

    assert %{start: 160, count: 40, finish: 200} =
             ScheduleWindow.build(slots(200), groups, 100_000, 40)

    small = [{2028, [%{cells: [{3, %{cell_id: "small"}}]}]}]

    assert %{start: 0, count: 3, groups: ^small, left_px: 0, right_px: 0} =
             ScheduleWindow.build(slots(3), small, 0, 40)

    assert %{start: 0, count: 0, total: 0, slots: [], groups: [], left_px: 0, right_px: 0} =
             ScheduleWindow.build([], [], 100, 40)
  end

  defp slots(count) do
    for index <- 0..(count - 1) do
      date = Date.add(~D[2026-07-01], index * 7)
      {1, index, date, Date.add(date, 6), index == 0}
    end
  end
end
