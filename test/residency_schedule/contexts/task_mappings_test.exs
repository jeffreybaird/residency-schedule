defmodule ResidencySchedule.TaskMappingsTest do
  use ResidencySchedule.DataCase

  alias ResidencySchedule.Assistant
  alias ResidencySchedule.DetailedSchedules.Activity
  alias ResidencySchedule.DetailedSchedules.ImportBatch
  alias ResidencySchedule.DetailedSchedules.TaskEquivalence
  alias ResidencySchedule.Ical
  alias ResidencySchedule.IdentityMappingDoctestFixtures
  alias ResidencySchedule.Importer.CsvParser
  alias ResidencySchedule.Importer.QgendaPreview
  alias ResidencySchedule.Rotations
  alias ResidencySchedule.TaskMappingDoctestFixtures
  alias ResidencySchedule.TaskMappings

  test "namespace-specific normalization retains the existing CSV and exact QGenda policies" do
    assert {:ok, %{lookup_key: "gyn", normalization_version: "csv_abbreviation_v1"}} =
             TaskMappings.normalize_key(:csv, " GYN - till 8p ")

    assert {:ok, %{lookup_key: " SMH GYN R2 Day ", normalization_version: "qgenda_exact_v1"}} =
             TaskMappings.normalize_key(:qgenda, " SMH GYN R2 Day ")

    assert {:error, :invalid_namespace} = TaskMappings.normalize_key(:other, "GYN")

    for value <- [nil, 12, "", "  ", <<0>>, String.duplicate("x", 513)] do
      assert {:error, :invalid_source_key} = TaskMappings.normalize_key(:qgenda, value)
    end
  end

  test "classify requires explicit seeding and never writes implicit seed data" do
    assert {:error, :not_seeded} = TaskMappings.classify(:qgenda, "Vacation")
    assert rows("source_task_mappings") == []
  end

  test "legacy seeds separate recognition, equivalence and namespace facts and are repeatable" do
    assert {:ok, first} = TaskMappings.seed_legacy()
    assert first.activity_types_added > 0
    assert first.mappings_added > 0
    assert first.conflicting == 0
    before = catalogue()

    assert {:ok, repeated} = TaskMappings.seed_legacy()
    assert repeated.activity_types_added == 0
    assert repeated.mappings_added == 0
    assert repeated.unchanged > 0
    assert catalogue() == before

    refute Enum.any?(rows("activity_types"), &(&1["code"] in ["unknown", "qgenda_assignment"]))
    assert Enum.all?(rows("source_task_mappings"), &(&1["evidence_origin"] == "legacy_code"))

    csv = Enum.filter(rows("source_task_mappings"), &(&1["namespace"] == "csv"))

    assert Enum.sort(Enum.map(csv, & &1["source_label"])) ==
             Enum.sort(Map.keys(CsvParser.rotation_abbreviations()))

    for mapping <- csv do
      assert mapping["lookup_key"] == CsvParser.normalize_task_label(mapping["source_label"])

      assert target_codes(mapping["id"]) == [
               Map.fetch!(CsvParser.rotation_abbreviations(), mapping["source_label"])
             ]
    end

    qgenda = Enum.filter(rows("source_task_mappings"), &(&1["namespace"] == "qgenda"))
    labels = Enum.uniq(QgendaPreview.known_tasks() ++ Map.keys(TaskEquivalence.equivalences()))
    assert Enum.sort(Enum.map(qgenda, & &1["source_label"])) == Enum.sort(labels)

    for mapping <- qgenda do
      assert mapping["recognized"] == mapping["source_label"] in QgendaPreview.known_tasks()

      assert target_codes(mapping["id"]) ==
               Enum.sort(Map.get(TaskEquivalence.equivalences(), mapping["source_label"], []))
    end

    assert {:ok, %{status: :resolved, activity_type_code: "strong_gynecology"}} =
             TaskMappings.classify(:csv, " GYN - till 8p ")

    assert {:ok, %{status: :unmapped, activity_type_code: nil}} =
             TaskMappings.classify(:qgenda, "GYN")
  end

  test "Qgenda exact labels distinguish unique meaning, recognition-only and unknown tasks" do
    seed!()

    assert {:ok, unique} = TaskMappings.classify(:qgenda, "SMH GYN R2 Day")
    assert unique.status == :resolved
    assert unique.activity_type_code == "strong_gynecology"
    assert unique.target_codes == ["strong_gynecology"]
    assert is_integer(unique.mapping_id)
    assert unique.mapping_revision == 1
    assert unique.rule_version == "legacy_task_classification_v1"

    assert {:ok, %{status: :recognized_unclassified, target_codes: [], activity_type_code: nil}} =
             TaskMappings.classify(:qgenda, "Lattimore MFM Clinic PM")

    for label <- ["SMH GYN R2 Day ", "smh gyn r2 day", "New GYN Night Clinic", "OFF"] do
      assert {:ok, %{status: :unmapped, target_codes: [], activity_type_code: nil}} =
               TaskMappings.classify(:qgenda, label)
    end
  end

  test "multi-target equivalents retain all targets and contextual policies without guessing" do
    seed!()

    assert {:ok, strong} =
             TaskMappings.classify(:qgenda, "SMH Obstetrics Resident 1st Contact Night")

    assert strong.status == :context_required
    assert strong.activity_type_code == nil
    assert strong.target_codes == ["night_float", "strong_weekend_nights"]

    assert {:ok, highland} = TaskMappings.classify(:qgenda, "HH Nights 3rd Call")
    assert highland.status == :context_required
    assert highland.target_codes == ["highland_night_float", "highland_weekend_nights"]
    assert highland.policy == "highland_saturday_gap_v1"
  end

  test "bounded backfill retains one result per occurrence and repeat makes no changes" do
    ctx = TaskMappingDoctestFixtures.source()

    other =
      TaskMappingDoctestFixtures.add_source(ctx, ctx.activity.raw_task, activity: ctx.activity)

    original = legacy_rows()
    seed!()

    assert {:ok, result} = TaskMappings.backfill(batch_size: 1)
    assert result.processed == 2
    assert result.resolved == 2
    assert result.conflicting == 0
    assert result.unchanged == 0
    saved = rows("activity_source_classifications")

    assert Enum.sort(Enum.map(saved, & &1["original_source_id"])) ==
             Enum.sort([ctx.source.id, other.source.id])

    assert Enum.all?(saved, &(&1["activity_type_code"] == "strong_gynecology"))
    assert Enum.all?(saved, &(&1["source_snapshot"] != %{} and &1["mapping_snapshot"] != %{}))

    assert {:ok, repeated} = TaskMappings.backfill(batch_size: 1)
    assert repeated.processed == 0
    assert repeated.unchanged == 2
    assert repeated.conflicting == 0
    assert rows("activity_source_classifications") == saved
    assert legacy_rows() == original
  end

  test "backfill counts all outcomes and leaves even Saturday multi-target results contextual" do
    ctx = TaskMappingDoctestFixtures.source("HH Nights 3rd Call")
    TaskMappingDoctestFixtures.add_source(ctx, "Vacation", date: ~D[2026-12-31])
    TaskMappingDoctestFixtures.add_source(ctx, "Lattimore MFM Clinic PM", date: ~D[2027-01-01])
    TaskMappingDoctestFixtures.add_source(ctx, "Unknown Clinic", date: ~D[2027-01-02])
    TaskMappingDoctestFixtures.add_source(ctx, "HH Nights 3rd Call", date: ~D[2027-01-02])
    seed!()

    assert {:ok, counts} = TaskMappings.backfill(batch_size: 2)
    assert counts.processed == 5
    assert counts.resolved == 1
    assert counts.context_required == 2
    assert counts.recognized_unclassified == 1
    assert counts.unmapped == 1
    assert counts.conflicting == 0
  end

  test "changed source facts preserve the previous classification and report conflict" do
    ctx = TaskMappingDoctestFixtures.source()
    seed!()
    assert {:ok, %{processed: 1}} = TaskMappings.backfill()
    original = rows("activity_source_classifications")

    Repo.update_all(from(a in Activity, where: a.id == ^ctx.activity.id),
      set: [raw_task: "Vacation"]
    )

    assert {:ok, %{processed: 0, conflicting: 1, unchanged: 0}} = TaskMappings.backfill()
    assert rows("activity_source_classifications") == original
    assert Repo.get!(Activity, ctx.activity.id).raw_task == "Vacation"
  end

  test "changed mapping input does not silently reclassify stored evidence" do
    TaskMappingDoctestFixtures.source()
    seed!()
    assert {:ok, %{processed: 1}} = TaskMappings.backfill()
    original = rows("activity_source_classifications")

    Repo.query!(
      "UPDATE source_task_mappings SET recognized = false WHERE source_label = 'SMH GYN R2 Day' AND namespace = 'qgenda'"
    )

    assert {:ok, %{processed: 0, conflicting: 1}} = TaskMappings.backfill()
    assert rows("activity_source_classifications") == original
  end

  test "legacy seed drift appends a revision without rewriting prior meaning or classifications" do
    TaskMappingDoctestFixtures.source()
    seed!()
    assert {:ok, %{processed: 1}} = TaskMappings.backfill()
    classifications = rows("activity_source_classifications")

    Repo.query!(
      "UPDATE source_task_mappings SET recognized=false WHERE namespace='qgenda' AND source_label='SMH GYN R2 Day'"
    )

    old =
      Enum.find(
        rows("source_task_mappings"),
        &(&1["namespace"] == "qgenda" and &1["source_label"] == "SMH GYN R2 Day")
      )

    targets =
      Repo.query!(
        "SELECT to_jsonb(t) FROM source_task_mapping_targets t WHERE mapping_id=$1 ORDER BY activity_type_code",
        [old["id"]]
      ).rows

    assert {:ok, %{mappings_added: 1}} = TaskMappings.seed_legacy()

    revisions =
      Enum.filter(
        rows("source_task_mappings"),
        &(&1["namespace"] == "qgenda" and &1["source_label"] == "SMH GYN R2 Day")
      )

    retired = Enum.find(revisions, &(&1["id"] == old["id"]))
    current = Enum.find(revisions, & &1["current"])
    assert length(revisions) == 2
    assert retired["current"] == false

    assert Map.drop(retired, ["current", "updated_at"]) ==
             Map.drop(old, ["current", "updated_at"])

    assert current["revision"] == old["revision"] + 1
    assert current["recognized"] == true

    assert Repo.query!(
             "SELECT to_jsonb(t) FROM source_task_mapping_targets t WHERE mapping_id=$1 ORDER BY activity_type_code",
             [old["id"]]
           ).rows == targets

    assert rows("activity_source_classifications") == classifications
    assert {:ok, %{mappings_added: 0}} = TaskMappings.seed_legacy()

    assert {:ok, %{status: :resolved, activity_type_code: "strong_gynecology"}} =
             TaskMappings.classify(:qgenda, "SMH GYN R2 Day")

    assert {:ok, %{processed: 0, conflicting: 1}} = TaskMappings.backfill()
    assert rows("activity_source_classifications") == classifications
  end

  test "seed and backfill preserve custom and reviewed evidence" do
    ctx = TaskMappingDoctestFixtures.source()
    seed!()
    assert {:ok, %{processed: 1}} = TaskMappings.backfill()

    Repo.query!(
      "UPDATE source_task_mappings SET evidence_origin='custom' WHERE source_label='SMH GYN R2 Day' AND namespace='qgenda'"
    )

    mappings = rows("source_task_mappings")
    assert {:ok, _} = TaskMappings.seed_legacy()
    assert rows("source_task_mappings") == mappings

    Repo.query!(
      "UPDATE activity_source_classifications SET evidence_origin='reviewed' WHERE original_source_id=$1",
      [ctx.source.id]
    )

    reviewed = rows("activity_source_classifications")

    Repo.update_all(from(a in Activity, where: a.id == ^ctx.activity.id),
      set: [raw_task: "Vacation"]
    )

    assert {:ok, %{processed: 0, unchanged: 1, conflicting: 0}} = TaskMappings.backfill()
    assert rows("activity_source_classifications") == reviewed
  end

  test "legacy backfill does not attribute custom mappings to a legacy classification" do
    TaskMappingDoctestFixtures.source()
    seed!()

    Repo.query!(
      "UPDATE source_task_mappings SET evidence_origin='custom' WHERE source_label='SMH GYN R2 Day' AND namespace='qgenda'"
    )

    assert {:ok, %{processed: 0, conflicting: 1, unchanged: 0}} = TaskMappings.backfill()
    assert rows("activity_source_classifications") == []
  end

  test "edited legacy target sets remain conflicting rather than becoming an invented unique meaning" do
    TaskMappingDoctestFixtures.source("HH Nights 3rd Call")
    seed!()
    assert {:ok, original} = TaskMappings.classify(:qgenda, "HH Nights 3rd Call")

    Repo.query!(
      "DELETE FROM source_task_mapping_targets WHERE mapping_id=$1 AND activity_type_code='highland_night_float'",
      [original.mapping_id]
    )

    assert {:ok, %{status: :conflicting, activity_type_code: nil}} =
             TaskMappings.classify(:qgenda, "HH Nights 3rd Call")

    assert {:ok, %{processed: 0, conflicting: 1}} = TaskMappings.backfill()
    assert rows("activity_source_classifications") == []
  end

  test "unsupported legacy rule versions cannot produce a new classification" do
    TaskMappingDoctestFixtures.source()
    seed!()

    Repo.query!(
      "UPDATE source_task_mappings SET rule_version='unsupported_future_rule' WHERE namespace='qgenda' AND source_label='SMH GYN R2 Day'"
    )

    assert {:ok, %{status: :conflicting, activity_type_code: nil}} =
             TaskMappings.classify(:qgenda, "SMH GYN R2 Day")

    assert {:ok, %{processed: 0, conflicting: 1}} = TaskMappings.backfill()
    assert rows("activity_source_classifications") == []
  end

  test "compiled release wrapper seeds and classifies explicitly with nested results" do
    TaskMappingDoctestFixtures.source()

    assert {:ok, %{seed: seed, classifications: %{processed: 1, resolved: 1}}} =
             ResidencySchedule.Release.backfill_task_classifications()

    assert seed.mappings_added > 0
  end

  test "bad batch scope is rejected without modifying legacy associations" do
    ctx = TaskMappingDoctestFixtures.source()
    other = IdentityMappingDoctestFixtures.seed()

    Repo.update_all(from(b in ImportBatch, where: b.id == ^ctx.batch.id),
      set: [schedule_id: other.schedule.id]
    )

    seed!()
    original = legacy_rows()
    assert {:error, :inconsistent_source_scope} = TaskMappings.backfill(batch_size: 1)
    assert rows("activity_source_classifications") == []
    assert legacy_rows() == original
  end

  test "unknown source kinds and invalid bounds do not invent a namespace" do
    TaskMappingDoctestFixtures.source("Vacation")
    seed!()

    for options <- [[batch_size: 0], [batch_size: 1001], [batch_size: "1"], [unknown: 1], :bad] do
      assert {:error, :invalid_batch_size} = TaskMappings.backfill(options)
    end

    Repo.query!("UPDATE detailed_import_batches SET source_kind='custom'")
    assert {:error, :unsupported_namespace} = TaskMappings.backfill()
    assert rows("activity_source_classifications") == []
  end

  test "invalid source tasks roll back their page while earlier bounded work remains retryable" do
    ctx = TaskMappingDoctestFixtures.source()
    TaskMappingDoctestFixtures.add_source(ctx, " ")
    seed!()
    original = legacy_rows()
    assert {:error, :invalid_source_task} = TaskMappings.backfill(batch_size: 1)
    [saved] = rows("activity_source_classifications")
    assert saved["original_source_id"] == ctx.source.id
    assert legacy_rows() == original
    assert {:error, :invalid_source_task} = TaskMappings.backfill(batch_size: 1)
    assert rows("activity_source_classifications") == [saved]
  end

  test "source deletion retains immutable evidence while releasing live references" do
    ctx = TaskMappingDoctestFixtures.source()
    seed!()
    assert {:ok, %{processed: 1}} = TaskMappings.backfill()
    [before] = rows("activity_source_classifications")
    Repo.delete!(ctx.source)
    [after_delete] = rows("activity_source_classifications")
    assert after_delete["activity_source_id"] == nil
    assert after_delete["original_source_id"] == ctx.source.id

    assert Map.drop(after_delete, ["activity_source_id"]) ==
             Map.drop(before, ["activity_source_id"])

    Repo.delete!(ctx.batch)
    Repo.delete!(ctx.activity)
    assert {:ok, _} = ResidencySchedule.Schedules.delete_schedule(ctx.schedule.id)
    assert rows("activity_source_classifications") == [after_delete]
  end

  test "database rejects duplicate original evidence, wrong namespace and unjustified targets" do
    TaskMappingDoctestFixtures.source()
    seed!()
    assert {:ok, %{processed: 1}} = TaskMappings.backfill()
    [classification] = rows("activity_source_classifications")

    assert_rejected("UPDATE activity_source_classifications SET namespace='csv' WHERE id=$1", [
      classification["id"]
    ])

    assert_rejected(
      "UPDATE activity_source_classifications SET mapping_revision=mapping_revision+1 WHERE id=$1",
      [classification["id"]]
    )

    assert_rejected(
      "UPDATE activity_source_classifications SET rule_version='other_rule_v1' WHERE id=$1",
      [classification["id"]]
    )

    assert_rejected(
      "UPDATE activity_source_classifications SET activity_type_code='vacation' WHERE id=$1",
      [classification["id"]]
    )

    assert_rejected("UPDATE activity_source_classifications SET status='unmapped' WHERE id=$1", [
      classification["id"]
    ])

    assert_rejected(
      "INSERT INTO source_task_mapping_targets (mapping_id,activity_type_code) VALUES ($1,'does_not_exist')",
      [classification["mapping_id"]]
    )

    assert_rejected(
      "INSERT INTO activity_source_classifications (original_source_id, activity_source_id, namespace, source_snapshot, mapping_snapshot, input_digest, mapping_id, mapping_revision, rule_version, status, activity_type_code, evidence_origin, inserted_at, updated_at) SELECT original_source_id, activity_source_id, namespace, source_snapshot, mapping_snapshot, input_digest, mapping_id, mapping_revision, rule_version, status, activity_type_code, evidence_origin, inserted_at, updated_at FROM activity_source_classifications WHERE id=$1",
      [classification["id"]]
    )
  end

  test "classification backfill leaves effective schedules and consumer meanings unchanged" do
    ctx = TaskMappingDoctestFixtures.source("HH Nights 3rd Call")

    {:ok, _} =
      Rotations.insert_rotations(ctx.member.id, [
        %{
          slot_index: 0,
          start_date: Date.new!(ctx.schedule.academic_year, 12, 28),
          end_date: Date.new!(ctx.schedule.academic_year + 1, 1, 3),
          rotation_type: :strong_gynecology
        }
      ])

    before = consumer_values(ctx)
    original = legacy_rows()
    seed!()
    assert {:ok, %{processed: 1}} = TaskMappings.backfill()
    assert consumer_values(ctx) == before
    assert legacy_rows() == original
  end

  defp seed!, do: assert({:ok, _} = TaskMappings.seed_legacy())

  defp rows(table),
    do: Repo.query!("SELECT to_jsonb(t) FROM #{table} t ORDER BY id").rows |> Enum.map(&hd/1)

  defp catalogue,
    do:
      Map.new(
        ["activity_types", "source_task_mappings", "source_task_mapping_targets"],
        &{&1, Repo.query!("SELECT to_jsonb(t) FROM #{&1} t ORDER BY to_jsonb(t)::text").rows}
      )

  defp legacy_rows,
    do:
      Map.new(
        [
          "detailed_import_batches",
          "detailed_activities",
          "detailed_activity_sources",
          "rotations"
        ],
        &{&1, rows(&1)}
      )

  defp assert_rejected(sql, params) do
    assert_raise Postgrex.Error, fn -> Repo.query!(sql, params, mode: :savepoint) end
  end

  defp target_codes(mapping_id) do
    Repo.query!(
      "SELECT activity_type_code FROM source_task_mapping_targets WHERE mapping_id=$1 ORDER BY activity_type_code",
      [mapping_id]
    ).rows
    |> Enum.map(&hd/1)
  end

  defp consumer_values(ctx) do
    %{
      resident: Rotations.resident_schedule_data(ctx.member),
      schedule: Rotations.effective_segments_for_schedule(ctx.schedule.id),
      coworkers: Rotations.list_coworker_shared_shift_counts(ctx.member.id),
      assistant:
        Assistant.resident_schedule(
          ctx.member.name,
          Date.new!(ctx.schedule.academic_year, 12, 28),
          Date.new!(ctx.schedule.academic_year + 1, 1, 3)
        ),
      calendar: Ical.build(ctx.member)
    }
  end
end
