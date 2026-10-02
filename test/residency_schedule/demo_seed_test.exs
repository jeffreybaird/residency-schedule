defmodule ResidencySchedule.DemoSeedTest do
  use ResidencySchedule.DataCase

  alias ResidencySchedule.Importer.CsvParser
  alias ResidencySchedule.Importer.ScheduleImporter
  alias ResidencySchedule.Release
  alias ResidencySchedule.Residents
  alias ResidencySchedule.Schedules

  describe "demo_csv_path/0" do
    test "points at a readable CSV inside the application" do
      assert File.exists?(Release.demo_csv_path())
    end
  end

  describe "demo schedule fixture" do
    setup do
      # Demo mode is what preserves the invented names: the fixture covers the
      # current academic year, which NameNormalizer maps to real residents.
      set_demo_mode(true)
      csv = File.read!(Release.demo_csv_path())
      {:ok, result, warnings} = ScheduleImporter.import_csv(csv)
      %{result: result, warnings: warnings}
    end

    test "imports every synthetic resident", %{result: result} do
      assert result.residents == 32
      assert result.rotations > 0
    end

    test "produces no unknown-rotation warnings", %{warnings: warnings} do
      assert warnings == []
    end

    test "keeps the invented names rather than canonical ones", %{result: result} do
      names =
        result.schedule_id
        |> Residents.list_residents_for_schedule()
        |> Enum.map(& &1.name)

      assert "Wren Halloway" in names
      refute "Juno R" in names
    end

    test "covers the current academic year so it renders on the calendar" do
      assert Schedules.get_by_year!(2026).label == "2026–2027"
    end

    test "canonical names are restored once demo mode is off" do
      set_demo_mode(false)
      csv = File.read!(Release.demo_csv_path())
      {:ok, result, _warnings} = ScheduleImporter.import_csv(csv)

      names =
        result.schedule_id
        |> Residents.list_residents_for_schedule()
        |> Enum.map(& &1.name)

      refute "Wren Halloway" in names
    end

    test "re-importing replaces the demo year without duplicating residents" do
      csv = File.read!(Release.demo_csv_path())
      {:ok, second, _warnings} = ScheduleImporter.import_csv(csv)

      assert second.residents == 32
      assert length(Residents.list_residents_for_schedule(second.schedule_id)) == 32
    end
  end

  describe "demo schedule realism" do
    # Regenerate the fixture with `python3 priv/demo/generate_demo_schedule.py`
    # if any of these fail after editing the template it is derived from.

    # Call and absence markers legitimately repeat within a class: they say
    # where a resident is *not*, so they carry no service-capacity meaning.
    @non_rotations [:post_call, :vacation, :float]

    setup do
      {:ok, residents, _warnings} =
        Release.demo_csv_path()
        |> File.read!()
        |> CsvParser.parse()

      %{residents: residents}
    end

    test "fields eight residents in every class", %{residents: residents} do
      counts =
        residents
        |> Enum.group_by(& &1.residency_year)
        |> Map.new(fn {year, members} -> {year, length(members)} end)

      assert counts == %{1 => 8, 2 => 8, 3 => 8, 4 => 8}
    end

    test "never puts two residents of one class on the same rotation at once", %{
      residents: residents
    } do
      assert double_booked_rotations(residents) == []
    end

    test "pairs every resident with each other class at least once", %{residents: residents} do
      assert unshared_cross_class_pairs(residents) == []
    end
  end

  defp double_booked_rotations(residents) do
    residents
    |> Enum.flat_map(fn resident ->
      resident.rotations
      |> Enum.reject(&(&1.rotation_type in @non_rotations))
      |> Enum.map(
        &{{resident.residency_year, &1.slot_index, &1.rotation_type}, resident.position_code}
      )
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_key, codes} -> length(codes) > 1 end)
  end

  defp unshared_cross_class_pairs(residents) do
    residents
    |> pair_combinations()
    |> Enum.reject(fn {a, b} ->
      a.residency_year == b.residency_year or shares_a_rotation?(a, b)
    end)
    |> Enum.map(fn {a, b} -> {a.position_code, b.position_code} end)
  end

  defp pair_combinations([]), do: []

  defp pair_combinations([head | tail]) do
    Enum.map(tail, &{head, &1}) ++ pair_combinations(tail)
  end

  defp shares_a_rotation?(a, b) do
    a
    |> rotation_keys()
    |> MapSet.intersection(rotation_keys(b))
    |> Enum.any?()
  end

  defp rotation_keys(resident) do
    resident.rotations
    |> Enum.map(&{&1.slot_index, &1.rotation_type})
    |> MapSet.new()
  end
end
