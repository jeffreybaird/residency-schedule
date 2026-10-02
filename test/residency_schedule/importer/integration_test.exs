defmodule ResidencySchedule.Importer.IntegrationTest do
  use ResidencySchedule.DataCase

  alias ResidencySchedule.Importer.ResidentLinker
  alias ResidencySchedule.Importer.ScheduleImporter
  alias ResidencySchedule.{Residents, Schedules}

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
      assert [_ | _] = briar.rotations
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
      assert [_ | _] = Residents.list_residents_for_schedule(Schedules.get_by_year!(2023).id)
      assert [_ | _] = Residents.list_residents_for_schedule(Schedules.get_by_year!(2026).id)
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

  describe "prepare/1 and commit/3 — admin-confirmed links" do
    setup do
      {:ok, _, _} = ScheduleImporter.import_csv(File.read!("test/fixtures/sample.csv"))
      :ok
    end

    test "prepare proposes existing people without writing anything" do
      people_before = length(Residents.list_residents())

      assert {:ok, prepared} =
               ScheduleImporter.prepare(File.read!("test/fixtures/schedule_2024_2025.csv"))

      assert prepared.academic_year == 2024
      assert Schedules.get_by_year(2024) == nil
      assert length(Residents.list_residents()) == people_before

      by_confidence = Enum.group_by(prepared.proposals, & &1.confidence)
      assert [_ | _] = by_confidence[:exact]
      assert [_ | _] = by_confidence[:none]
      assert Enum.all?(by_confidence[:exact], &(&1.proposed_id != nil))
    end

    test "prepare returns an error for an empty file" do
      assert {:error, _} = ScheduleImporter.prepare("")
    end

    test "commit writes the confirmed links and creates the rest" do
      {:ok, prepared} =
        ScheduleImporter.prepare(File.read!("test/fixtures/schedule_2024_2025.csv"))

      links = ResidentLinker.links_from_params(prepared.proposals, %{})
      people_before = Residents.list_residents()

      assert {:ok, %{schedule_id: schedule_id}} =
               ScheduleImporter.commit(prepared.parsed, 2024, links)

      new_count = Enum.count(links, fn {_code, link} -> link == :new end)
      assert length(Residents.list_residents()) == length(people_before) + new_count

      linked_person_ids = for {_code, id} when is_integer(id) <- links, do: id

      persisted_person_ids =
        schedule_id
        |> Residents.list_residents_for_schedule()
        |> Enum.map(& &1.resident_id)

      assert Enum.all?(linked_person_ids, &(&1 in persisted_person_ids))
    end

    test "commit honours an admin override that links a row to a chosen person" do
      {:ok, prepared} =
        ScheduleImporter.prepare(File.read!("test/fixtures/schedule_2024_2025.csv"))

      unmatched = Enum.find(prepared.proposals, &(&1.confidence == :none))
      # Briar graduates after 2023, so no 2024 row is proposed for them.
      briar = Residents.get_resident_by_position!("R4-1")
      refute Enum.any?(prepared.proposals, &(&1.proposed_id == briar.resident_id))

      links =
        ResidentLinker.links_from_params(prepared.proposals, %{
          unmatched.position_code => to_string(briar.resident_id)
        })

      assert {:ok, %{schedule_id: schedule_id}} =
               ScheduleImporter.commit(prepared.parsed, 2024, links)

      linked =
        schedule_id
        |> Residents.list_residents_for_schedule()
        |> Enum.find(&(&1.position_code == unmatched.position_code))

      assert linked.resident_id == briar.resident_id
      assert linked.name == briar.name
    end

    test "commit refuses a new resident whose name already exists" do
      {:ok, prepared} =
        ScheduleImporter.prepare(File.read!("test/fixtures/schedule_2024_2025.csv"))

      matched = Enum.find(prepared.proposals, &(&1.confidence == :exact))

      links =
        ResidentLinker.links_from_params(prepared.proposals, %{
          matched.position_code => "new"
        })

      assert {:error, message} = ScheduleImporter.commit(prepared.parsed, 2024, links)

      assert message =~
               "#{matched.position_code}: a resident named #{matched.name} already exists"

      assert Schedules.get_by_year(2024) == nil
    end

    test "commit rejects an empty row list" do
      assert {:error, _} = ScheduleImporter.commit([], 2024, %{})
    end
  end
end
