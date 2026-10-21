defmodule ResidencySchedule.SourceProvenanceTest do
  use ResidencySchedule.DataCase

  alias ResidencySchedule.DetailedSchedules
  alias ResidencySchedule.DetailedSchedules.{Activity, ActivitySource, ImportBatch}
  alias ResidencySchedule.Importer.Adapters.Csv
  alias ResidencySchedule.Importer.{Preview, ScheduleImporter}
  alias ResidencySchedule.Rotations.Rotation
  alias ResidencySchedule.ScheduleBuilder
  alias ResidencySchedule.ScheduleEditor
  alias ResidencySchedule.ScheduleFixtures
  alias ResidencySchedule.SourceProvenance

  test "backfill fills known QGenda references in small batches and preserves original records" do
    %{schedule: schedule, clare: resident} = ScheduleFixtures.seed_mini_schedule()
    sources = source_rows(schedule.id, resident.id, 5)
    before = legacy_snapshot()

    assert {:ok, %{activity_sources_updated: 5}} = SourceProvenance.backfill(batch_size: 2)

    for source <- sources do
      saved = Repo.get!(ActivitySource, source.id)

      assert Map.get(saved, :source_reference) == %{
               "sheet" => source.source_sheet,
               "cell" => source.source_cell
             }
    end

    assert legacy_snapshot() == before
    batch = Repo.get!(ImportBatch, hd(sources).batch_id)
    assert Map.get(batch, :source_kind) == "qgenda"
    assert Map.get(batch, :source_metadata) == %{}
    assert {:ok, %{activity_sources_updated: 0}} = SourceProvenance.backfill(batch_size: 1)
    assert legacy_snapshot() == before
  end

  test "resuming skips populated custom references and non-QGenda documents" do
    %{schedule: schedule, clare: resident} = ScheduleFixtures.seed_mini_schedule()
    [first, second, third] = source_rows(schedule.id, resident.id, 3)
    custom = %{"external_id" => "source-42", "details" => %{"revision" => 7}}

    Repo.query!("UPDATE detailed_activity_sources SET source_reference = $1 WHERE id = $2", [
      custom,
      first.id
    ])

    Repo.query!(
      "UPDATE detailed_import_batches SET source_kind = 'custom', source_metadata = $1 WHERE id = $2",
      [%{"document_id" => "external-1"}, third.batch_id]
    )

    before = legacy_snapshot()

    assert {:ok, %{activity_sources_updated: 1}} = SourceProvenance.backfill(batch_size: 1)
    assert Map.get(Repo.get!(ActivitySource, first.id), :source_reference) == custom

    assert Map.get(Repo.get!(ActivitySource, second.id), :source_reference) == %{
             "sheet" => second.source_sheet,
             "cell" => second.source_cell
           }

    assert Map.get(Repo.get!(ActivitySource, third.id), :source_reference) == %{}

    assert Map.get(Repo.get!(ImportBatch, third.batch_id), :source_metadata) == %{
             "document_id" => "external-1"
           }

    assert legacy_snapshot() == before
    assert {:ok, %{activity_sources_updated: 0}} = SourceProvenance.backfill()
  end

  test "backfill rejects invalid batch sizes without writes" do
    before = legacy_snapshot()

    for size <- [0, -1, 1001, "2", nil] do
      assert {:error, _} = SourceProvenance.backfill(batch_size: size)
    end

    for options <- [nil, [:not_a_keyword], %{batch_size: 1}, [unknown: true]] do
      assert {:error, _} = SourceProvenance.backfill(options)
    end

    assert legacy_snapshot() == before
    assert {:ok, %{activity_sources_updated: 0}} = SourceProvenance.backfill(batch_size: 1000)
  end

  test "new QGenda commits write generic provenance and keep fingerprint/reimport identity" do
    admin = ScheduleFixtures.admin_user()
    %{schedule: schedule} = ResidencySchedule.QgendaDetailFixtures.seed_detail_roster()
    binary = File.read!("test/fixtures/qgenda/shared.xlsx")

    assert {:ok, preview} =
             Preview.prepare(:qgenda, binary, academic_year: schedule.academic_year)

    assert {:ok, result} = DetailedSchedules.commit(preview, admin)
    batch = Repo.get!(ImportBatch, result.batch_id)
    assert batch.fingerprint == preview.fingerprint
    assert Map.get(batch, :source_kind) == "qgenda"
    assert Map.get(batch, :source_metadata) == %{}
    sources = Repo.all(from s in ActivitySource, where: s.batch_id == ^batch.id)
    assert sources != []

    for source <- sources do
      assert Map.get(source, :source_reference) == %{
               "sheet" => source.source_sheet,
               "cell" => source.source_cell
             }
    end

    before = legacy_snapshot()
    assert {:ok, repeated} = DetailedSchedules.commit(preview, admin)
    assert repeated.batch_id == batch.id
    assert repeated.inserted == 0
    assert legacy_snapshot() == before
    assert {:ok, %{activity_sources_updated: 0}} = SourceProvenance.backfill()
  end

  test "an unmigrated database returns a retryable backfill error" do
    prefix = "provenance_unmigrated_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{prefix}")
    Repo.query!("SET LOCAL search_path TO #{prefix}, public")
    Repo.query!("CREATE TABLE detailed_import_batches (id bigint PRIMARY KEY)")
    Repo.query!("CREATE TABLE detailed_activity_sources (id bigint PRIMARY KEY, batch_id bigint)")

    assert {:error, message} = SourceProvenance.backfill()
    assert message =~ "retried"
    refute message =~ "source_reference"

    # The SQL sandbox isolates the failed query; the surrounding test transaction
    # owns and removes this synthetic schema without a second manual savepoint.
    Repo.query!("SET LOCAL search_path TO public")
    Repo.query!("DROP SCHEMA #{prefix} CASCADE")
  end

  test "CSV and builder stamp known origins while unknown legacy writes remain honest" do
    assert {:ok, imported, []} =
             ScheduleImporter.import_csv(csv("2032-07-05", "2032-07-09", "GYN"))

    imported_rows = rotations_for(imported.schedule_id)
    assert imported_rows != []

    assert Enum.all?(
             imported_rows,
             &(Map.get(&1, :source_kind) == "csv" and Map.get(&1, :source_metadata) == %{})
           )

    {:ok, state} = ScheduleBuilder.generate(2033)
    assert {:ok, built} = ScheduleBuilder.save(state)
    assert rotations_for(built.schedule_id) != []

    assert Enum.all?(
             rotations_for(built.schedule_id),
             &(Map.get(&1, :source_kind) == "builder" and Map.get(&1, :source_metadata) == %{})
           )

    %{clare: resident} = ScheduleFixtures.seed_mini_schedule()

    unknown =
      Repo.insert!(%Rotation{
        schedule_resident_id: resident.id,
        rotation_type: "vacation",
        start_date: ~D[2026-08-03],
        end_date: ~D[2026-08-07],
        slot_index: 20
      })

    assert Map.get(unknown, :source_kind) == "legacy"
    assert Map.get(unknown, :source_metadata) == %{}
  end

  test "date updates preserve fragment provenance and stamp only new CSV assignments" do
    assert {:ok, imported, []} =
             ScheduleImporter.import_csv(csv("2034-07-03", "2034-07-21", "GYN"))

    [original] = rotations_for(imported.schedule_id)
    metadata = %{"document_id" => "old-roster", "row" => 12}

    Repo.query!(
      "UPDATE rotations SET source_kind = 'custom', source_metadata = $1 WHERE id = $2",
      [metadata, original.id]
    )

    assert {:ok, _, []} =
             ScheduleImporter.import_csv(csv("2034-07-10", "2034-07-14", "AMB"),
               mode: :update_dates,
               academic_year: 2034
             )

    rows = rotations_for(imported.schedule_id)
    assert length(rows) == 3
    [replacement] = Enum.filter(rows, &(&1.rotation_type == "ambulatory"))
    assert Map.get(replacement, :source_kind) == "csv"
    assert Map.get(replacement, :source_metadata) == %{}
    fragments = Enum.reject(rows, &(&1.id == replacement.id))

    assert Enum.all?(
             fragments,
             &(Map.get(&1, :source_kind) == "custom" and Map.get(&1, :source_metadata) == metadata)
           )
  end

  test "editor records actual changes but no-op saves preserve provenance and timestamps" do
    %{schedule: schedule, clare: resident} = ScheduleFixtures.seed_mini_schedule()
    original = hd(rotations_for(schedule.id))
    metadata = %{"document_id" => "original-roster"}

    Repo.query!("UPDATE rotations SET source_kind = 'csv', source_metadata = $1 WHERE id = $2", [
      metadata,
      original.id
    ])

    original = Repo.get!(Rotation, original.id)
    assert {:ok, state} = ScheduleEditor.load(schedule.id)
    assert {:ok, _} = ScheduleEditor.commit(state, [])

    assert {:ok, _} =
             ScheduleEditor.commit(state, [
               %{
                 action: :update,
                 rotation_id: original.id,
                 attrs: %{rotation_type: original.rotation_type}
               }
             ])

    assert Repo.get!(Rotation, original.id) == original

    assert {:ok, _} =
             ScheduleEditor.commit(state, [
               %{action: :update, rotation_id: original.id, attrs: %{rotation_type: "ambulatory"}}
             ])

    saved = Repo.get!(Rotation, original.id)
    assert saved.id == original.id
    assert Map.get(saved, :source_kind) == "editor"
    assert Map.get(saved, :source_metadata) == %{}

    assert {:ok, state} = ScheduleEditor.load(schedule.id)

    assert {:ok, _} =
             ScheduleEditor.commit(state, [
               %{
                 action: :add,
                 schedule_resident_id: resident.id,
                 attrs: %{
                   rotation_type: "vacation",
                   start_date: ~D[2026-08-03],
                   end_date: ~D[2026-08-07]
                 }
               }
             ])

    added =
      Repo.one!(
        from r in Rotation,
          where: r.schedule_resident_id == ^resident.id and r.start_date == ^~D[2026-08-03]
      )

    assert Map.get(added, :source_kind) == "editor"
    assert Map.get(added, :source_metadata) == %{}
  end

  test "provenance fields are not accepted as user assignment attributes" do
    %{schedule: schedule} = ScheduleFixtures.seed_mini_schedule()
    original = hd(rotations_for(schedule.id))
    assert {:ok, state} = ScheduleEditor.load(schedule.id)
    before = legacy_snapshot()

    for forged <- [%{source_kind: "qgenda"}, %{source_metadata: %{"trusted" => true}}] do
      assert {:error, _} =
               ScheduleEditor.commit(state, [
                 %{
                   action: :update,
                   rotation_id: original.id,
                   attrs: Map.put(forged, :rotation_type, "ambulatory")
                 }
               ])

      assert legacy_snapshot() == before
    end

    changeset =
      Rotation.changeset(original, %{source_kind: "qgenda", source_metadata: %{"trusted" => true}})

    refute Map.has_key?(changeset.changes, :source_kind)
    refute Map.has_key?(changeset.changes, :source_metadata)
  end

  test "compiled-release backfill entry point returns the same idempotent result" do
    %{schedule: schedule, clare: resident} = ScheduleFixtures.seed_mini_schedule()
    [_] = source_rows(schedule.id, resident.id, 1)

    assert {:ok, %{activity_sources_updated: 1}} =
             ResidencySchedule.Release.backfill_source_provenance()

    assert {:ok, %{activity_sources_updated: 0}} =
             ResidencySchedule.Release.backfill_source_provenance()
  end

  test "unknown persist callers remain legacy and invalid origin options cannot write" do
    assert {:ok, document} =
             Csv.parse(
               csv("2040-07-02", "2040-07-06", "GYN"),
               []
             )

    before = legacy_snapshot()

    for kind <- ["untrusted_origin", 123] do
      assert {:error, _} =
               ScheduleImporter.persist(document.residents, 2040, source_kind: kind)

      assert legacy_snapshot() == before
    end

    for options <- [nil, [:not_a_keyword], %{source_kind: "csv"}, [unknown: true]] do
      assert {:error, _} = ScheduleImporter.persist(document.residents, 2040, options)
      assert legacy_snapshot() == before
    end

    assert {:ok, saved} = ScheduleImporter.persist(document.residents, 2040)
    rotations = rotations_for(saved.schedule_id)
    assert rotations != []
    assert Enum.all?(rotations, &(Map.get(&1, :source_kind) == "legacy"))
  end

  defp source_rows(schedule_id, resident_id, count) do
    now = ~U[2025-01-01 12:00:00Z]

    for index <- 1..count do
      batch =
        Repo.insert!(%ImportBatch{
          schedule_id: schedule_id,
          fingerprint: "legacy-#{index}",
          header_start: ~D[2026-07-06],
          header_end: ~D[2026-07-06],
          inserted_at: now,
          updated_at: now
        })

      activity =
        Repo.insert!(%Activity{
          schedule_resident_id: resident_id,
          date: ~D[2026-07-06],
          raw_task: "Legacy task #{index}",
          inserted_at: now,
          updated_at: now
        })

      Repo.insert!(%ActivitySource{
        activity_id: activity.id,
        batch_id: batch.id,
        source_sheet: "July",
        source_cell: "B#{index}",
        raw_staff: "Iris Reed",
        display_name: "Iris Reed",
        previous_name: "Iris",
        notes: [%{"text" => "Retain this note"}],
        inserted_at: now,
        updated_at: now
      })
    end
  end

  defp rotations_for(schedule_id) do
    Repo.all(
      from r in Rotation,
        join: sr in assoc(r, :schedule_resident),
        where: sr.schedule_id == ^schedule_id,
        order_by: r.id
    )
  end

  defp legacy_snapshot do
    for table <- [
          "schedules",
          "residents",
          "schedule_residents",
          "rotations",
          "detailed_import_batches",
          "detailed_activities",
          "detailed_activity_sources",
          "schedule_change_requests",
          "shift_overrides"
        ] do
      {table,
       Repo.query!(
         "SELECT to_jsonb(t) - 'source_kind' - 'source_metadata' - 'source_reference' FROM #{table} t ORDER BY id"
       ).rows}
    end
  end

  defp csv(first, last, type),
    do: ",Dates,#{first}\n,,#{last}\n,,Events\nR1-1,Iris Reed,#{type}\n"
end
