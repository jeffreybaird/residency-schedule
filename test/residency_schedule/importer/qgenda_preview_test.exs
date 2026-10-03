defmodule ResidencySchedule.Importer.QgendaPreviewTest do
  use ResidencySchedule.DataCase, async: true

  alias ResidencySchedule.Importer.QgendaPreview
  alias ResidencySchedule.{Repo, Residents, Schedules}
  alias ResidencySchedule.Residents.{Resident, ScheduleResident}
  alias ResidencySchedule.Rotations.Rotation

  setup do
    {:ok, schedule} = Schedules.upsert_schedule(2026, "2026–2027")

    roster =
      ["Iris Reed", "Juniper Vail", "Parker Missing", "Iris Stone", "iris stone"]
      |> Enum.with_index(1)
      |> Enum.map(fn {name, index} ->
        {:ok, resident} =
          Residents.insert_resident(schedule.id, %{
            name: name,
            position_code: "R2-#{index}",
            residency_year: 2,
            schedule_number: index
          })

        resident
      end)

    %{
      roster: roster,
      options: [
        academic_year: 2026,
        aliases: %{
          "Vale, Juniper" => %{position_code: "R2-2", expected_name: "Juniper Vail"}
        }
      ]
    }
  end

  test "retains simultaneous tasks, source coordinates, linked notes and QGenda names", %{
    options: options,
    roster: [iris, juniper | _]
  } do
    assert {:ok, preview} = QgendaPreview.prepare(workbook(), options)
    assert length(preview.assignments) == 12
    gyn = Enum.find(preview.assignments, &(&1.source_cell == "B6"))
    assert gyn.date == ~D[2026-12-28]
    assert gyn.raw_staff == "Reed, Iris"
    assert gyn.raw_task == "SMH GYN R2 Day"
    assert gyn.source_sheet == "Page 1"
    same_day_clinic = Enum.find(preview.assignments, &(&1.source_cell == "B7"))
    assert same_day_clinic.date == gyn.date
    assert same_day_clinic.resident_id == gyn.resident_id
    assert same_day_clinic.raw_task == "GOG Continuity Clinic AM"
    assert gyn.resident_id == iris.resident_id
    assert gyn.schedule_resident_id == iris.id
    clinic = Enum.find(preview.assignments, &(&1.source_cell == "D6"))
    assert clinic.notes == ["Bring simulation kit"]

    assert Enum.find(preview.assignments, &(&1.source_cell == "D7")).notes == [
             "Coverage discussion"
           ]

    refute inspect(preview) =~ "555-0100"
    match = Enum.find(preview.matches, &(&1.raw_staff == "Vale, Juniper"))
    assert match.status == :matched
    assert match.display_name == "Juniper Vale"
    assert match.previous_name == "Juniper Vail"
    assert match.resident_id == juniper.resident_id
  end

  test "matches only full names or reviewed aliases; flags missing and ambiguous people", %{
    options: options
  } do
    assert {:ok, preview} = QgendaPreview.prepare(workbook(), options)
    assert Enum.find(preview.matches, &(&1.raw_staff == "Guest, Rowan")).status == :unmatched
    ambiguous = Enum.find(preview.matches, &(&1.raw_staff == "Stone, Iris"))
    assert ambiguous.status == :ambiguous
    assert ambiguous.resident_id == nil
    # An uppercase full name is still the same person, not a new identity.
    assert Enum.find(preview.matches, &(&1.raw_staff == "IRIS REED")).status == :matched
    assert Enum.any?(preview.missing_residents, &(&1.name == "Parker Missing"))
    blank = Enum.find(preview.assignments, &(&1.source_cell == "D8"))
    assert blank.resident_id == nil
    assert blank.raw_staff == ""
    assert preview.unknown_tasks == ["Mystery Service"]
  end

  test "no first-name or stale crosswalk fallback and roster is year scoped", %{options: options} do
    {:ok, without_alias} = QgendaPreview.prepare(workbook(), academic_year: 2026)

    assert Enum.find(without_alias.matches, &(&1.raw_staff == "Vale, Juniper")).status ==
             :unmatched

    stale =
      Keyword.put(options, :aliases, %{
        "Vale, Juniper" => %{position_code: "R2-2", expected_name: "Someone Else"}
      })

    {:ok, stale_preview} = QgendaPreview.prepare(workbook(), stale)
    assert Enum.find(stale_preview.matches, &(&1.raw_staff == "Vale, Juniper")).resident_id == nil
    assert {:error, reason} = QgendaPreview.prepare(workbook(), academic_year: 2025)
    assert is_binary(reason)
  end

  test "reports header dates separately from matched coverage across seven pairs and year rollover",
       %{options: options} do
    {:ok, preview} = QgendaPreview.prepare(workbook(), options)
    assert preview.header_range == {~D[2026-12-28], ~D[2027-01-04]}
    assert preview.resident_range == {~D[2026-12-28], ~D[2027-01-02]}

    assert preview.uncovered_dates == [
             ~D[2026-12-31],
             ~D[2027-01-01],
             ~D[2027-01-03],
             ~D[2027-01-04]
           ]

    assert Enum.find(preview.assignments, &(&1.source_cell == "N6")).date == ~D[2027-01-03]
  end

  test "inline strings and shared strings have the same assignment meaning", %{options: options} do
    {:ok, shared} = QgendaPreview.prepare(workbook(), options)
    {:ok, inline} = QgendaPreview.prepare(File.read!("test/fixtures/qgenda/inline.xlsx"), options)
    assert shared.assignments == inline.assignments
    assert shared.matches == inline.matches
  end

  test "repeated preview is deterministic and never changes persisted data", %{options: options} do
    before = snapshot()
    assert {:ok, first} = QgendaPreview.prepare(workbook(), options)
    assert {:ok, second} = QgendaPreview.prepare(workbook(), options)
    assert first == second
    assert is_binary(first.fingerprint)
    assert snapshot() == before
  end

  test "rejects malformed archives, XML, traversal and oversized expanded entries", %{
    options: options
  } do
    for binary <- [
          "not a zip",
          replace_part("xl/worksheets/sheet1.xml", "<broken>"),
          replace_part(
            "xl/sharedStrings.xml",
            "<!DOCTYPE s [<!ENTITY x SYSTEM 'file:///etc/passwd'>]><s>&x;</s>"
          ),
          replace_part("../escape.xml", "unsafe"),
          replace_part("xl/sharedStrings.xml", String.duplicate("x", 21_000_000))
        ] do
      assert {:error, reason} = QgendaPreview.prepare(binary, options)
      assert is_binary(reason)
    end
  end

  test "missing target year and forged expanded ZIP sizes return errors", %{options: options} do
    assert {:error, _} = QgendaPreview.prepare(workbook(), academic_year: nil)

    assert {:error, _} =
             QgendaPreview.prepare(
               File.read!("test/fixtures/qgenda/forged-expanded-size.xlsx"),
               options
             )
  end

  test "an unlinked schedule note is retained for review rather than assigned to a similar person",
       %{options: options} do
    {:ok, entries} = :zip.extract(workbook(), [:memory])

    {_, strings} =
      Enum.find(entries, fn {name, _} -> to_string(name) == "xl/sharedStrings.xml" end)

    strings =
      String.replace(
        strings,
        "Reed, Iris SMH GYN R2 Day Coverage discussion",
        "Reed, Unknown SMH GYN R2 Day Coverage discussion"
      )

    {:ok, preview} = QgendaPreview.prepare(replace_part("xl/sharedStrings.xml", strings), options)
    refute Enum.any?(preview.assignments, &("Coverage discussion" in &1.notes))
    assert Enum.any?(preview.unlinked_notes, &String.contains?(&1.text, "Coverage discussion"))
  end

  defp workbook, do: File.read!("test/fixtures/qgenda/shared.xlsx")

  defp replace_part(path, content) do
    {:ok, entries} = :zip.extract(workbook(), [:memory])
    entries = Enum.reject(entries, fn {name, _} -> to_string(name) == path end)

    {:ok, {_, binary}} =
      :zip.create(~c"test.xlsx", [{String.to_charlist(path), content} | entries], [:memory])

    binary
  end

  defp snapshot do
    for schema <- [Resident, ScheduleResident, Rotation, ResidencySchedule.Schedules.Schedule],
        into: %{},
        do: {schema, Repo.all(schema)}
  end
end
