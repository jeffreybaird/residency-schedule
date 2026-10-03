defmodule ResidencySchedule.DetailedSchedulesTest do
  use ResidencySchedule.DataCase
  import ResidencySchedule.QgendaDetailFixtures
  import ResidencySchedule.ScheduleFixtures, only: [admin_user: 0, unlinked_user: 0]
  alias ResidencySchedule.{Accounts, DetailedSchedules, Repo, Schedules}
  alias ResidencySchedule.Importer.ScheduleImporter

  setup do
    data = seed_detail_roster()
    {:ok, preview} = detail_preview()
    Map.merge(data, %{preview: preview, admin: admin_user()})
  end

  test "saves matched activity detail and provenance without changing base schedules", ctx do
    before = base_snapshot()
    assert {:ok, result} = DetailedSchedules.commit(ctx.preview, ctx.admin)
    assert result.inserted == 8
    assert result.skipped == 4

    [clinic] =
      DetailedSchedules.list_for_resident(ctx.iris.id, ~D[2026-12-29])
      |> Enum.filter(&(&1.raw_task == "GOG Continuity Clinic PM"))

    assert clinic.period == "PM"
    assert clinic.site == "GOG"
    assert clinic.raw_staff == "Reed, Iris"
    assert clinic.notes == ["Bring simulation kit"]

    assert Enum.any?(clinic.sources, fn source ->
             Enum.any?(
               source.notes,
               &(&1.source_cell == "A15" and &1.text == "Bring simulation kit")
             )
           end)

    assert Enum.any?(
             clinic.sources,
             &(&1.source_sheet == "Page 1" and &1.source_cell == "D6" and
                 &1.batch_id == result.batch_id)
           )

    unknown = DetailedSchedules.list_for_resident(ctx.stone.id, ~D[2026-12-31]) |> hd()
    assert unknown.raw_task == "Mystery Service"
    assert unknown.period == nil
    assert unknown.site == nil
    assert DetailedSchedules.list_for_date(ctx.schedule.id, ~D[2027-01-03]) == []
    assert base_snapshot() == before
  end

  test "identical imports reuse batch and activities without duplicate notes", ctx do
    {:ok, first} = DetailedSchedules.commit(ctx.preview, ctx.admin)
    before = DetailedSchedules.list_for_date(ctx.schedule.id, ~D[2026-12-29])
    assert {:ok, second} = DetailedSchedules.commit(ctx.preview, ctx.admin)
    assert second.batch_id == first.batch_id
    assert second.inserted == 0
    assert second.existing == 8
    assert DetailedSchedules.list_for_date(ctx.schedule.id, ~D[2026-12-29]) == before
  end

  test "overlapping changed files add provenance and new tasks without deleting old details",
       ctx do
    {:ok, first} = DetailedSchedules.commit(ctx.preview, ctx.admin)

    binary =
      mutate_detail_workbook(
        "xl/sharedStrings.xml",
        &String.replace(&1, "Mystery Service", "Additional Service")
      )

    {:ok, preview} = detail_preview(binary)
    {:ok, second} = DetailedSchedules.commit(preview, ctx.admin)
    assert second.batch_id != first.batch_id
    assert second.inserted == 1
    assert second.existing == 7

    tasks =
      DetailedSchedules.list_for_resident(ctx.stone.id, ~D[2026-12-31]) |> Enum.map(& &1.raw_task)

    assert Enum.sort(tasks) == ["Additional Service", "Mystery Service"]

    clinic =
      DetailedSchedules.list_for_resident(ctx.iris.id, ~D[2026-12-29])
      |> Enum.find(&(&1.raw_task == "GOG Continuity Clinic PM"))

    assert clinic.notes == ["Bring simulation kit"]
    assert clinic.sources |> Enum.map(& &1.batch_id) |> Enum.uniq() |> length() == 2
  end

  test "duplicate logical source rows share one activity but retain both occurrences", ctx do
    binary =
      mutate_detail_workbook("xl/worksheets/sheet1.xml", fn xml ->
        [_, value] = Regex.run(~r/<c r="D6" t="s"><v>(\d+)<\/v><\/c>/, xml)

        Regex.replace(
          ~r/<c r="D7" t="s"><v>\d+<\/v><\/c>/,
          xml,
          "<c r=\"D7\" t=\"s\"><v>#{value}</v></c>"
        )
      end)

    {:ok, preview} = detail_preview(binary)
    assert {:ok, result} = DetailedSchedules.commit(preview, ctx.admin)
    assert result.inserted == 7
    [clinic] = DetailedSchedules.list_for_resident(ctx.iris.id, ~D[2026-12-29])
    assert clinic.sources |> Enum.map(& &1.source_cell) |> Enum.sort() == ["D6", "D7"]
  end

  test "nonadmins, anonymous and revoked admins cannot save", ctx do
    assert {:error, _} = DetailedSchedules.commit(ctx.preview, nil)
    assert {:error, _} = DetailedSchedules.commit(ctx.preview, unlinked_user())
    admin_user()
    {:ok, _} = Accounts.set_role(ctx.admin, :resident)
    assert {:error, _} = DetailedSchedules.commit(ctx.preview, ctx.admin)
    assert DetailedSchedules.list_for_date(ctx.schedule.id, ~D[2026-12-28]) == []
  end

  test "renamed roster identity invalidates entire preview transaction", ctx do
    person = Repo.get!(ResidencySchedule.Residents.Resident, ctx.juniper.resident_id)
    person |> Ecto.Changeset.change(name: "Renamed Person") |> Repo.update!()
    assert {:error, _} = DetailedSchedules.commit(ctx.preview, ctx.admin)
    assert DetailedSchedules.list_for_date(ctx.schedule.id, ~D[2026-12-28]) == []
    assert DetailedSchedules.list_for_date(ctx.schedule.id, ~D[2026-12-30]) == []
  end

  test "changed roster position invalidates preview", ctx do
    Repo.get!(ResidencySchedule.Residents.ScheduleResident, ctx.juniper.id)
    |> Ecto.Changeset.change(position_code: "R2-9")
    |> Repo.update!()

    assert {:error, _} = DetailedSchedules.commit(ctx.preview, ctx.admin)
    assert DetailedSchedules.list_for_date(ctx.schedule.id, ~D[2026-12-28]) == []
  end

  test "cross-year or missing roster identities reject the whole import", ctx do
    {:ok, other} = Schedules.upsert_schedule(2025, "2025–2026")
    forged = Map.put(ctx.preview, :schedule_id, other.id)
    assert {:error, _} = DetailedSchedules.commit(forged, ctx.admin)
    Repo.get!(ResidencySchedule.Residents.ScheduleResident, ctx.juniper.id) |> Repo.delete!()
    assert {:error, _} = DetailedSchedules.commit(ctx.preview, ctx.admin)
    assert DetailedSchedules.list_for_date(ctx.schedule.id, ~D[2026-12-28]) == []
  end

  test "CSV replacement preview and direct commit cannot destroy saved activities", ctx do
    csv = File.read!("test/fixtures/sample_2026.csv")
    {:ok, prepared} = ScheduleImporter.prepare(csv)
    {:ok, _} = DetailedSchedules.commit(ctx.preview, ctx.admin)
    before = base_snapshot()
    assert {:error, _} = ScheduleImporter.prepare(csv)
    assert {:error, _} = ScheduleImporter.commit(prepared.parsed, 2026, %{})
    assert {:error, _} = ScheduleImporter.persist(prepared.parsed, 2026)
    assert base_snapshot() == before
    assert DetailedSchedules.list_for_date(ctx.schedule.id, ~D[2026-12-28]) != []
  end

  test "partial reimports never clear dates absent from the new file", ctx do
    {:ok, _} = DetailedSchedules.commit(ctx.preview, ctx.admin)
    before = DetailedSchedules.list_for_resident(ctx.iris.id, ~D[2026-12-28])

    binary =
      mutate_detail_workbook("xl/worksheets/sheet1.xml", fn xml ->
        Regex.replace(~r/<row r="[78]">.*?<\/row>/s, xml, "")
      end)

    {:ok, partial} = detail_preview(binary)
    assert {:ok, _} = DetailedSchedules.commit(partial, ctx.admin)
    after_rows = DetailedSchedules.list_for_resident(ctx.iris.id, ~D[2026-12-28])

    assert Enum.map(after_rows, & &1.id) |> Enum.sort() ==
             Enum.map(before, & &1.id) |> Enum.sort()
  end

  test "base date updates preserve detailed clinic assignments", ctx do
    {:ok, _} = DetailedSchedules.commit(ctx.preview, ctx.admin)
    before = DetailedSchedules.list_for_resident(ctx.iris.id, ~D[2026-12-29])
    csv = ",Dates,2026-12-29\n,,2026-12-29\nR2-1,Iris Reed,GYN\n"

    assert {:ok, _, _} =
             ScheduleImporter.import_csv(csv, mode: :update_dates, academic_year: 2026)

    assert DetailedSchedules.list_for_resident(ctx.iris.id, ~D[2026-12-29]) == before
  end

  test "save rejects workbook dates from another year", ctx do
    binary =
      mutate_detail_workbook("xl/sharedStrings.xml", fn xml ->
        xml |> String.replace("2026", "2024") |> String.replace("2027", "2025")
      end)

    {:ok, preview} = detail_preview(binary)
    assert {:error, _} = DetailedSchedules.commit(preview, ctx.admin)
    assert DetailedSchedules.list_for_date(ctx.schedule.id, ~D[2024-12-28]) == []
  end

  test "June orientation dates belong to the selected academic year", ctx do
    replacements = [
      {"December 28, 2026", "June 18, 2026"},
      {"December 29, 2026", "June 19, 2026"},
      {"December 30, 2026", "June 20, 2026"},
      {"December 31, 2026", "June 21, 2026"},
      {"January 1, 2027", "June 22, 2026"},
      {"January 2, 2027", "June 23, 2026"},
      {"January 3, 2027", "June 24, 2026"},
      {"January 4, 2027", "June 25, 2026"}
    ]

    binary =
      mutate_detail_workbook("xl/sharedStrings.xml", fn xml ->
        Enum.reduce(replacements, xml, fn {old, new}, acc -> String.replace(acc, old, new) end)
      end)

    {:ok, preview} = detail_preview(binary)
    assert {:ok, _} = DetailedSchedules.commit(preview, ctx.admin)
    assert DetailedSchedules.list_for_resident(ctx.iris.id, ~D[2026-06-18]) != []
  end

  test "two save requests leave one logical result", ctx do
    results =
      [
        Task.async(fn -> DetailedSchedules.commit(ctx.preview, ctx.admin) end),
        Task.async(fn -> DetailedSchedules.commit(ctx.preview, ctx.admin) end)
      ]
      |> Enum.map(&Task.await/1)

    assert Enum.all?(results, &match?({:ok, _}, &1))

    assert results |> Enum.map(fn {:ok, result} -> result.batch_id end) |> Enum.uniq() |> length() ==
             1

    assert DetailedSchedules.list_for_resident(ctx.iris.id, ~D[2026-12-29]) |> length() == 2
  end

  defp base_snapshot do
    for schema <- [
          ResidencySchedule.Residents.Resident,
          ResidencySchedule.Residents.ScheduleResident,
          ResidencySchedule.Rotations.Rotation,
          ResidencySchedule.Schedules.Schedule
        ],
        into: %{},
        do: {schema, Repo.all(schema)}
  end
end
