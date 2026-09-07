defmodule ResidencySchedule.Importer.IntegrationTest do
  use ResidencySchedule.DataCase

  alias ResidencySchedule.Importer.ScheduleImporter
  alias ResidencySchedule.{Schedules, Residents}

  describe "full pipeline: CSV binary → database rows" do
    test "imports all residents and rotations from the 2023 fixture" do
      csv = File.read!("test/fixtures/sample.csv")

      assert {:ok, %{residents: r_count, rotations: rot_count}, _warnings} =
               ScheduleImporter.import_csv(csv)

      assert r_count > 0
      assert rot_count > 0

      pos = Residents.get_resident_by_position!("R4-1")
      briar = Residents.get_resident!(pos.id)
      assert briar.name == "Briar"
      assert length(briar.rotations) > 0
    end

    test "re-importing the same CSV replaces data without duplication" do
      csv = File.read!("test/fixtures/sample.csv")
      {:ok, first, _} = ScheduleImporter.import_csv(csv)
      {:ok, second, _} = ScheduleImporter.import_csv(csv)
      assert first.residents == second.residents
      assert first.rotations == second.rotations
    end

    test "re-importing keeps the person record, its token, and users' home link" do
      csv = File.read!("test/fixtures/sample.csv")
      {:ok, _, _} = ScheduleImporter.import_csv(csv)

      before = Residents.get_resident!(Residents.get_resident_by_position!("R4-1").id)

      {:ok, user} =
        ResidencySchedule.Accounts.create_user(%{email: "briar@urmc.rochester.edu"})

      {:ok, _} = ResidencySchedule.Accounts.set_home_resident(user, before.resident_id)

      {:ok, _, _} = ScheduleImporter.import_csv(csv)

      after_import = Residents.get_resident!(Residents.get_resident_by_position!("R4-1").id)

      refute after_import.id == before.id
      assert after_import.resident_id == before.resident_id
      assert after_import.resident.calendar_token == before.resident.calendar_token
      assert ResidencySchedule.Accounts.get_user!(user.id).home_resident_id == before.resident_id
    end

    test "the same name in two academic years resolves to one person" do
      {:ok, _, _} = ScheduleImporter.import_csv(File.read!("test/fixtures/sample.csv"))

      {:ok, _, _} =
        ScheduleImporter.import_csv(File.read!("test/fixtures/schedule_2024_2025.csv"))

      people_by_name =
        Residents.list_residents()
        |> Enum.group_by(& &1.name)
        |> Enum.filter(fn {_name, rows} -> length(rows) > 1 end)

      assert people_by_name == []

      shared =
        Residents.list_residents()
        |> Enum.map(&Residents.list_appearances_for_person(&1.id))
        |> Enum.filter(&(length(&1) > 1))

      assert shared != []
    end

    test "importing a second academic year does not affect the first" do
      csv_2023 = File.read!("test/fixtures/sample.csv")
      csv_2026 = File.read!("test/fixtures/sample_2026.csv")
      {:ok, _, _} = ScheduleImporter.import_csv(csv_2023)
      {:ok, _, _} = ScheduleImporter.import_csv(csv_2026)

      assert Schedules.get_by_year!(2023).label == "2023–2024"
      assert Schedules.get_by_year!(2026).label == "2026–2027"
      assert length(Residents.list_residents_for_schedule(Schedules.get_by_year!(2023).id)) > 0
      assert length(Residents.list_residents_for_schedule(Schedules.get_by_year!(2026).id)) > 0
    end

    test "year rollover is corrected — January dates show year+1" do
      csv = File.read!("test/fixtures/sample.csv")
      {:ok, _, _} = ScheduleImporter.import_csv(csv)

      pos = Residents.get_resident_by_position!("R4-1")
      briar = Residents.get_resident!(pos.id)

      all_dates =
        Enum.flat_map(briar.rotations, &[&1.start_date, &1.end_date])

      bad = Enum.filter(all_dates, fn d -> d.month in 1..6 and d.year == 2023 end)
      assert bad == [], "Found uncorrected year-rollover dates: #{inspect(bad)}"
    end

    test "import_csv returns error for empty binary" do
      assert {:error, _reason} = ScheduleImporter.import_csv("")
    end

    test "backtick junk cell produces a warning, not a crash" do
      csv = File.read!("test/fixtures/sample.csv")
      {:ok, _summary, warnings} = ScheduleImporter.import_csv(csv)
      backtick = Enum.find(warnings, fn {_code, _idx, val} -> val == "`" end)
      assert backtick != nil
    end
  end
end
