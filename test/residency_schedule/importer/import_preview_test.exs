defmodule ResidencySchedule.Importer.ImportPreviewTest do
  use ResidencySchedule.DataCase, async: true

  alias ResidencySchedule.DetailedSchedules
  alias ResidencySchedule.DetailedSchedules.{Activity, ActivitySource, ImportBatch}

  alias ResidencySchedule.Importer.{
    Preview,
    QgendaParser,
    QgendaPreview,
    ResidentLinker,
    ScheduleImporter
  }

  alias ResidencySchedule.{Residents, Schedules}
  alias ResidencySchedule.Residents.{Resident, ScheduleResident}
  alias ResidencySchedule.Rotations.Rotation
  alias ResidencySchedule.ScheduleFixtures

  setup do
    {:ok, schedule} = Schedules.upsert_schedule(2026, "2026–2027")

    {:ok, resident} =
      Residents.insert_resident(schedule.id, %{
        name: "Iris Reed",
        position_code: "R2-1",
        residency_year: 2,
        schedule_number: 1
      })

    %{schedule: schedule, resident: resident}
  end

  test "common CSV preview agrees with legacy preview and remains committable without parser input" do
    binary = File.read!("test/fixtures/sample.csv")
    before = snapshot()
    assert {:ok, legacy} = ScheduleImporter.prepare(binary)
    assert {:ok, common} = Preview.prepare(:csv, binary, [])
    assert common.parsed == legacy.parsed
    assert common.proposals == legacy.proposals
    assert common.warnings == legacy.warnings
    assert common.academic_year == legacy.academic_year
    assert snapshot() == before

    assert Enum.all?(
             common.parsed,
             &is_struct(&1, ResidencySchedule.Importer.ImportDocument.Resident)
           )

    links = ResidentLinker.links_from_params(common.proposals, %{})
    assert {:ok, result} = ScheduleImporter.commit(common.parsed, common.academic_year, links)
    assert result.residents == length(common.parsed)
    assert result.rotations > 0
  end

  test "QGenda previews retain legacy fingerprint and all reconciliation results" do
    binary = File.read!("test/fixtures/qgenda/shared.xlsx")
    options = [academic_year: 2026]
    before = snapshot()
    assert {:ok, parsed} = QgendaParser.parse(binary)
    assert {:ok, legacy} = QgendaPreview.prepare(binary, options)
    assert {:ok, common} = Preview.prepare(:qgenda, binary, options)

    for field <- [
          :assignments,
          :matches,
          :warnings,
          :notes,
          :unlinked_notes,
          :unknown_tasks,
          :roster_snapshot
        ] do
      assert Map.fetch!(common, field) == Map.fetch!(legacy, field)
    end

    fingerprint =
      :crypto.hash(:sha256, :erlang.term_to_binary(parsed)) |> Base.encode16(case: :lower)

    assert common.fingerprint == fingerprint
    assert legacy.fingerprint == fingerprint
    assert snapshot() == before
  end

  test "a new JSON adapter reuses reconciliation without persistence", %{resident: resident} do
    before = snapshot()
    assert {:ok, preview} = Preview.prepare(:json, json(), academic_year: 2026)
    assert preview.preview_only
    assert preview.academic_year == 2026
    assert length(preview.assignments) == 2
    assert Enum.all?(preview.assignments, &(&1.resident_id == resident.resident_id))
    assert Enum.all?(preview.assignments, &(&1.schedule_resident_id == resident.id))
    assert preview.unknown_tasks == ["Clinic AM", "Mystery Service"]
    assert hd(preview.assignments).notes == ["Bring kit"]
    assert preview.header_range == {~D[2026-12-28], ~D[2026-12-29]}
    assert preview.uncovered_dates == [~D[2026-12-29]]
    assert snapshot() == before
    assert {:ok, repeated} = Preview.prepare(:json, json(), academic_year: 2026)
    assert preview == repeated
  end

  test "preview-only JSON cannot use the existing detailed commit API even for an admin" do
    admin = ScheduleFixtures.admin_user()
    before = snapshot()
    assert {:ok, preview} = Preview.prepare(:json, json(), academic_year: 2026)
    assert {:error, _} = DetailedSchedules.commit(preview, admin)
    assert snapshot() == before
  end

  test "JSON matches full names conservatively and preserves unknown people for review" do
    payload = Jason.decode!(json())

    assignments =
      for name <- ["Iris", "Guest, Rowan", "Reed, Iris"] do
        %{"date" => "2026-12-28", "raw_staff" => name, "raw_task" => "Mystery Service"}
      end

    assert {:ok, preview} =
             Preview.prepare(:json, Jason.encode!(%{payload | "assignments" => assignments}),
               academic_year: 2026
             )

    assert Enum.find(preview.matches, &(&1.raw_staff == "Iris")).status == :unmatched
    assert Enum.find(preview.matches, &(&1.raw_staff == "Guest, Rowan")).status == :unmatched
    assert Enum.find(preview.matches, &(&1.raw_staff == "Reed, Iris")).status == :matched
    assert Enum.all?(preview.assignments, &is_binary(&1.source_cell))
    assert Enum.all?(preview.assignments, &is_binary(&1.source_sheet))
  end

  test "common preview rejects unsupported formats, missing target years and conflicting JSON years" do
    assert {:error, _} = Preview.prepare(:unsupported, "data", [])
    assert {:error, _} = Preview.prepare(:json, json(), academic_year: 2025)
    assert {:error, _} = Preview.prepare(:json, json(), academic_year: 2040)

    assert {:error, _} =
             Preview.prepare(:qgenda, File.read!("test/fixtures/qgenda/shared.xlsx"), [])

    assert {:error, _} = Preview.prepare(:csv, "", mode: :unsupported)
  end

  defp json do
    Jason.encode!(%{
      academic_year: 2026,
      header_dates: ["2026-12-28", "2026-12-29"],
      assignments: [
        %{
          date: "2026-12-28",
          raw_staff: "Reed, Iris",
          raw_task: "Mystery Service",
          notes: ["Bring kit"]
        },
        %{date: "2026-12-28", raw_staff: "Reed, Iris", raw_task: "Clinic AM", notes: []}
      ]
    })
  end

  defp snapshot do
    for schema <- [
          Resident,
          ScheduleResident,
          Rotation,
          Schedules.Schedule,
          Activity,
          ActivitySource,
          ImportBatch
        ],
        into: %{},
        do: {schema, Repo.all(schema)}
  end
end
