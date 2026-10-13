defmodule ResidencyScheduleWeb.ScheduleCellIndexTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.ScheduleCellReference
  alias ResidencyScheduleWeb.ScheduleLive.Index

  @first ~D[2026-07-01]

  test "slot start decides coverage, inclusive boundaries and reversed intervals retain old behavior" do
    slots = [{1, 0, day(0), day(6), true}, {1, 1, day(7), day(7), false}]

    rotations = [
      rotation(1, 0, 0, "oncology"),
      rotation(2, 2, 6, "elective"),
      rotation(3, 7, 7, "float"),
      rotation(4, 5, 3, "invalid_interval")
    ]

    assert [{1, %{id: 1, start_date: start, end_date: last}}, {1, %{id: 3}}] =
             equivalent(slots, %{1 => rotations})

    assert start == day(0)
    assert last == day(6)
  end

  test "equal type ties retain original order and duplicate rotations" do
    slots = [{1, 0, day(0), day(0), true}]

    rotations = [
      rotation(8, 0, 2, "float"),
      rotation(3, 0, 1, "float"),
      rotation(8, 0, 2, "float"),
      rotation(9, 0, 0, "ambulatory")
    ]

    assert [{1, %{rotations: overlapping}}] = equivalent(slots, %{1 => rotations})
    assert Enum.map(overlapping, & &1.id) == [9, 8, 3, 8]
  end

  test "adjacent types and source tasks merge across ids and retain the first identity" do
    slots = for i <- 0..3, do: {1, i, day(i), day(i), i == 0}

    rotations = [
      rotation(7, 0, 0, "float", ["AM"]),
      rotation(2, 1, 1, "float", ["AM"]),
      rotation(3, 2, 2, "float", ["PM"]),
      rotation(4, 3, 3, "float", ["AM"])
    ]

    assert [{2, %{id: 7, cell_id: token}}, {1, %{id: 3}}, {1, %{id: 4}}] =
             equivalent(slots, %{1 => rotations})

    assert is_binary(token) and byte_size(token) > 0
  end

  test "gaps and schedule boundaries prevent merging while original irregular slot order is preserved" do
    slots = [
      {1, 10, day(4), day(4), false},
      {1, 5, day(0), day(0), true},
      {1, 6, day(0), day(1), false},
      {1, 8, day(3), day(3), false},
      {2, 0, day(4), day(4), true}
    ]

    lookup = %{1 => [rotation(1, 0, 4, "float")], 2 => [rotation(2, 0, 4, "float")]}
    assert length(equivalent(slots, lookup)) == 5
  end

  test "empty list suppresses legacy fallback whereas absent and nil schedule keys permit it" do
    slots = [{1, 9, day(0), day(0), true}]
    legacy = %{{1, 9} => rotation(33, 0, 0, "float")}
    assert [{1, %{id: 33}}] = equivalent(slots, legacy)
    assert [{1, %{id: 33}}] = equivalent(slots, Map.put(legacy, 1, nil))
    assert [{1, nil}] = equivalent(slots, Map.put(legacy, 1, []))
    assert [] == equivalent([], legacy)
    assert [{1, nil}] = equivalent(slots, %{})
  end

  test "deterministic generated combinations preserve full annotated output and inputs" do
    for seed <- 1..40 do
      :rand.seed(:exsss, {seed, seed + 1, seed + 2})

      slots =
        for i <- 0..39 do
          first = :rand.uniform(45) - 1
          {rem(i, 2) + 1, rem(i, 7), day(first), day(first + :rand.uniform(4) - 1), i < 2}
        end

      lookup =
        for schedule <- 1..2, into: %{} do
          rotations =
            for id <- 1..30 do
              first = :rand.uniform(45) - 1
              type = Enum.at(["float", "elective", "float", "oncology"], :rand.uniform(4) - 1)
              rotation(id, first, first + :rand.uniform(10) - 2, type, ["task#{rem(id, 3)}"])
            end

          {schedule, rotations}
        end

      equivalent(slots, lookup)
    end
  end

  test "doubling sparse rotations and slots takes less than triple the BEAM reductions" do
    small = sparse_fixture(512)
    large = sparse_fixture(1024)
    {slots, lookup} = small
    Index.cell_groups_unified(slots, lookup)

    small_reductions =
      reductions(fn -> Index.cell_groups_unified(elem(small, 0), elem(small, 1)) end)

    large_reductions =
      reductions(fn -> Index.cell_groups_unified(elem(large, 0), elem(large, 1)) end)

    assert large_reductions < small_reductions * 3,
           "expected indexed growth, got #{small_reductions} -> #{large_reductions} reductions"
  end

  defp equivalent(slots, lookup) do
    original = :erlang.term_to_binary({slots, lookup})
    expected = ScheduleCellReference.groups(slots, lookup)
    actual = Index.cell_groups_unified(slots, lookup)
    assert actual == expected
    assert :erlang.term_to_binary({slots, lookup}) == original
    actual
  end

  defp sparse_fixture(count) do
    slots = for i <- 0..(count - 1), do: {1, i, day(i), day(i), i == 0}

    rotations =
      for i <- 0..(count - 1),
          do: rotation(i, i, i, if(rem(i, 2) == 0, do: "float", else: "oncology"))

    {slots, %{1 => rotations}}
  end

  defp reductions(fun) do
    {:reductions, before} = Process.info(self(), :reductions)
    result = fun.()
    {:reductions, after_count} = Process.info(self(), :reductions)
    assert result != []
    after_count - before
  end

  defp rotation(id, first, last, type, tasks \\ []) do
    %{
      id: id,
      schedule_resident_id: 99,
      rotation_type: type,
      start_date: day(first),
      end_date: day(last),
      source_tasks: tasks,
      opaque: {:preserve, id}
    }
  end

  defp day(offset), do: Date.add(@first, offset)
end
