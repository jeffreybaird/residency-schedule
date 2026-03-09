defmodule ResidencySchedule.Importer.IntegrationTest do
  use ResidencySchedule.DataCase

  alias ResidencySchedule.Importer.ScheduleImporter
  alias ResidencySchedule.{Schedules, Residents}

  describe "full pipeline: CSV binary → database rows" do
    test "imports all residents and rotations from the 2023 fixture" do
      csv = File.read!("test/fixtures/sample_schedule.csv")

      assert {:ok, %{residents: r_count, rotations: rot_count}, _warnings} =
               ScheduleImporter.import_csv(csv)

      assert r_count > 0
      assert rot_count > 0

      pos = Residents.get_resident_by_position!("R4-1")
      alexis = Residents.get_resident!(pos.id)
      assert alexis.name == "Alexis"
      assert length(alexis.rotations) > 0
    end

    test "re-importing the same CSV replaces data without duplication" do
      csv = File.read!("test/fixtures/sample_schedule.csv")
      {:ok, first, _} = ScheduleImporter.import_csv(csv)
      {:ok, second, _} = ScheduleImporter.import_csv(csv)
      assert first.residents == second.residents
      assert first.rotations == second.rotations
    end

    test "importing a second academic year does not affect the first" do
      csv_2023 = File.read!("test/fixtures/sample_schedule.csv")
      csv_2026 = File.read!("test/fixtures/sample_schedule_2026.csv")
      {:ok, _, _} = ScheduleImporter.import_csv(csv_2023)
      {:ok, _, _} = ScheduleImporter.import_csv(csv_2026)

      assert Schedules.get_by_year!(2023).label == "2023–2024"
      assert Schedules.get_by_year!(2026).label == "2026–2027"
      assert length(Residents.list_residents_for_schedule(Schedules.get_by_year!(2023).id)) > 0
      assert length(Residents.list_residents_for_schedule(Schedules.get_by_year!(2026).id)) > 0
    end

    test "year rollover is corrected — January dates show year+1" do
      csv = File.read!("test/fixtures/sample_schedule.csv")
      {:ok, _, _} = ScheduleImporter.import_csv(csv)

      pos = Residents.get_resident_by_position!("R4-1")
      alexis = Residents.get_resident!(pos.id)

      all_dates =
        Enum.flat_map(alexis.rotations, &[&1.start_date, &1.end_date])

      bad = Enum.filter(all_dates, fn d -> d.month in 1..6 and d.year == 2023 end)
      assert bad == [], "Found uncorrected year-rollover dates: #{inspect(bad)}"
    end

    test "import_csv returns error for empty binary" do
      assert {:error, _reason} = ScheduleImporter.import_csv("")
    end

    test "backtick junk cell produces a warning, not a crash" do
      csv = File.read!("test/fixtures/sample_schedule.csv")
      {:ok, _summary, warnings} = ScheduleImporter.import_csv(csv)
      backtick = Enum.find(warnings, fn {_code, _idx, val} -> val == "`" end)
      assert backtick != nil
    end
  end
end
