defmodule ResidencySchedule.DemoSeedTest do
  use ResidencySchedule.DataCase

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
      assert result.residents == 16
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
      refute "Paige R" in names
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

      assert second.residents == 16
      assert length(Residents.list_residents_for_schedule(second.schedule_id)) == 16
    end
  end
end
