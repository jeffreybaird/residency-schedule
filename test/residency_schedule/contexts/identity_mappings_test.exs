defmodule ResidencySchedule.IdentityMappingsTest do
  use ResidencySchedule.DataCase

  doctest ResidencySchedule.IdentityMappings
  doctest ResidencySchedule.IdentityMappings.Key
  doctest ResidencySchedule.IdentityMappings.State

  alias ResidencySchedule.DetailedSchedules.{Activity, ActivitySource, ImportBatch}
  alias ResidencySchedule.IdentityMappings
  alias ResidencySchedule.Importer.ScheduleImporter
  alias ResidencySchedule.Residents
  alias ResidencySchedule.ScheduleBuilder
  alias ResidencySchedule.Schedules
  alias ResidencySchedule.Schedules.Schedule
  import ResidencySchedule.QgendaDetailFixtures
  import ResidencySchedule.ScheduleFixtures, only: [admin_user: 0, unlinked_user: 0]

  setup do
    Map.put(seed_detail_roster(), :admin, admin_user())
  end

  test "normalization is versioned and namespaces remain distinct" do
    assert {:ok, %{lookup_key: "iris reed", normalization_version: "qgenda_full_name_v1"}} =
             IdentityMappings.normalize_key(:qgenda, "  Reed,  Iris ")

    assert {:ok, %{lookup_key: "reed, iris", normalization_version: "csv_alias_v1"}} =
             IdentityMappings.normalize_key(:csv, "  Reed,  Iris ")

    assert {:error, :invalid_namespace} = IdentityMappings.normalize_key(:other, "Iris")

    for key <- [nil, 12, "  ", String.duplicate("x", 513)] do
      assert {:error, :invalid_source_key} = IdentityMappings.normalize_key(:csv, key)
    end
  end

  test "exact full names retain independent matching, while first names and collisions do not",
       ctx do
    assert {:ok, %{status: :matched, reason: :exact_name, schedule_resident_id: id}} =
             IdentityMappings.resolve(ctx.schedule.id, :qgenda, "Reed, Iris")

    assert id == ctx.iris.id

    assert {:ok, %{status: :unmatched}} =
             IdentityMappings.resolve(ctx.schedule.id, :qgenda, "Iris")

    {:ok, _} =
      Residents.insert_resident(ctx.schedule.id, %{
        name: "iris stone",
        position_code: "R2-4",
        residency_year: 2,
        schedule_number: 4
      })

    assert {:ok, %{status: :ambiguous}} =
             IdentityMappings.resolve(ctx.schedule.id, :qgenda, "Stone, Iris")

    assert {:error, :not_found} = IdentityMappings.resolve(-1, :csv, "Iris Reed")
  end

  test "dry run is read only and approval records actual actor, with repeat approvals unchanged",
       ctx do
    assert {:ok, plan} = prepare(ctx, "Legacy Iris")
    assert plan.summary == %{additions: 1, existing: 0, held: 0, conflicts: 0}
    assert mappings() == []

    assert {:ok, %{approved: 1, unchanged: 0}} =
             IdentityMappings.approve_crosswalk(plan, ctx.admin)

    [saved] = mappings()
    assert saved["approved_by_id"] == ctx.admin.id
    assert saved["target_snapshot"]["resident_id"] == ctx.iris.resident_id
    assert saved["target_snapshot"]["schedule_resident_id"] == ctx.iris.id

    assert {:ok, %{status: :matched, reason: :approved_mapping, schedule_resident_id: id}} =
             IdentityMappings.resolve(ctx.schedule.id, :csv, " legacy  iris ")

    assert id == ctx.iris.id
    assert {:ok, repeated} = prepare(ctx, "Legacy Iris")
    assert repeated.summary.existing == 1

    assert {:ok, %{approved: 0, unchanged: 1}} =
             IdentityMappings.approve_crosswalk(repeated, ctx.admin)

    assert mappings() == [saved]
  end

  test "scope and namespace isolate identical aliases", ctx do
    approve!(ctx, "Legacy Iris")
    {:ok, other_schedule} = Schedules.upsert_schedule(2025, "2025–2026")

    {:ok, other} =
      Residents.insert_resident(other_schedule.id, %{
        name: "Other Person",
        position_code: "R2-1",
        residency_year: 2,
        schedule_number: 1
      })

    other_ctx = %{ctx | schedule: other_schedule, iris: other}
    approve!(other_ctx, "Legacy Iris")

    assert {:ok, %{status: :matched, schedule_resident_id: id}} =
             IdentityMappings.resolve(other_schedule.id, :csv, "Legacy Iris")

    assert id == other.id

    assert {:ok, %{status: :unmatched}} =
             IdentityMappings.resolve(ctx.schedule.id, :qgenda, "Legacy Iris")
  end

  test "both operations recheck persisted administrator access", ctx do
    user = unlinked_user()
    forged = %{user | role: :admin}

    assert {:error, :forbidden} =
             IdentityMappings.prepare_crosswalk(
               ctx.schedule.id,
               :csv,
               [row(ctx.iris, "Legacy Iris")],
               forged
             )

    assert {:ok, plan} = prepare(ctx, "Legacy Iris")
    Repo.query!("UPDATE users SET role = 'resident' WHERE id = $1", [ctx.admin.id])
    assert {:error, :forbidden} = IdentityMappings.approve_crosswalk(plan, ctx.admin)
    assert mappings() == []
  end

  test "crosswalk bounds and roster checks reject unsafe approvals", ctx do
    for rows <- [
          nil,
          [],
          [%{}],
          List.duplicate(row(ctx.iris, "Alias"), 1001),
          [row(ctx.iris, String.duplicate("x", 513))]
        ] do
      assert {:error, :invalid_crosswalk} =
               IdentityMappings.prepare_crosswalk(ctx.schedule.id, :csv, rows, ctx.admin)
    end

    assert {:error, :invalid_crosswalk} =
             IdentityMappings.prepare_crosswalk(
               ctx.schedule.id,
               :csv,
               [row(ctx.iris, "Alias"), row(ctx.juniper, " alias ")],
               ctx.admin
             )

    bad = %{row(ctx.iris, "Alias") | expected_name: "Wrong Person"}

    assert {:ok, plan} =
             IdentityMappings.prepare_crosswalk(ctx.schedule.id, :csv, [bad], ctx.admin)

    assert plan.summary.held == 1
    assert {:error, :held} = IdentityMappings.approve_crosswalk(plan, ctx.admin)
    assert mappings() == []
  end

  test "roster or mapping changes stale a prepared review atomically", ctx do
    assert {:ok, plan} = prepare(ctx, "Legacy Iris")

    Repo.query!("UPDATE residents SET name = 'Iris Renamed' WHERE id = $1", [ctx.iris.resident_id])

    assert {:error, :stale_plan} = IdentityMappings.approve_crosswalk(plan, ctx.admin)
    assert mappings() == []
    Repo.query!("UPDATE residents SET name = 'Iris Reed' WHERE id = $1", [ctx.iris.resident_id])
    assert {:ok, old} = prepare(ctx, "Legacy Iris")
    approve!(ctx, "Different Alias")
    assert {:error, :stale_plan} = IdentityMappings.approve_crosswalk(old, ctx.admin)
    assert length(mappings()) == 1
  end

  test "explicit retargeting appends revision and preserves prior meaning", ctx do
    approve!(ctx, "Alias")
    [original] = mappings()

    assert {:ok, plan} =
             IdentityMappings.prepare_crosswalk(
               ctx.schedule.id,
               :csv,
               [row(ctx.juniper, "Alias")],
               ctx.admin
             )

    assert {:ok, %{approved: 1}} = IdentityMappings.approve_crosswalk(plan, ctx.admin)
    [retired, current] = mappings()
    assert retired["target_snapshot"] == original["target_snapshot"]
    assert retired["revision"] == original["revision"]
    refute retired["current"]
    assert current["current"]
    assert current["revision"] > original["revision"]

    assert {:ok, %{status: :matched, schedule_resident_id: id}} =
             IdentityMappings.resolve(ctx.schedule.id, :csv, "Alias")

    assert id == ctx.juniper.id
  end

  test "bounded backfill preserves source facts and never promotes convergent aliases", ctx do
    source!(ctx, ctx.iris, "Old Alias", 1)
    source!(ctx, ctx.iris, "Old Alias", 2)
    before = source_facts()

    assert {:ok, %{observations_added: 2, unchanged: 0, conflicting_keys: 0}} =
             IdentityMappings.backfill(batch_size: 1)

    assert {:ok, %{status: :held, reason: :observed_only}} =
             IdentityMappings.resolve(ctx.schedule.id, :qgenda, "Old Alias")

    assert Enum.all?(mappings(), &(&1["status"] == "observed" and is_nil(&1["approved_by_id"])))

    assert {:ok, %{observations_added: 0, unchanged: 2, conflicting_keys: 0}} =
             IdentityMappings.backfill(batch_size: 1)

    assert source_facts() == before

    assert {:ok, %{observations_added: 0}} =
             ResidencySchedule.Release.backfill_identity_mappings()

    for size <- [0, 1001, "1"] do
      assert {:error, :invalid_batch_size} = IdentityMappings.backfill(batch_size: size)
    end
  end

  test "conflicting observations count distinct keys across pages and block approval", ctx do
    source!(ctx, ctx.iris, "Old Alias", 1)
    source!(ctx, ctx.juniper, "Old Alias", 2)
    source!(ctx, ctx.stone, "Old Alias", 3)

    assert {:ok, %{observations_added: 3, conflicting_keys: 1}} =
             IdentityMappings.backfill(batch_size: 1)

    assert {:ok, %{status: :ambiguous}} =
             IdentityMappings.resolve(ctx.schedule.id, :qgenda, "Old Alias")

    assert {:ok, plan} =
             IdentityMappings.prepare_crosswalk(
               ctx.schedule.id,
               :qgenda,
               [row(ctx.iris, "Old Alias")],
               ctx.admin
             )

    assert plan.summary.conflicts == 1
    assert {:error, :conflict} = IdentityMappings.approve_crosswalk(plan, ctx.admin)
  end

  test "new contradictory observations hold an already approved alias", ctx do
    assert {:ok, plan} =
             IdentityMappings.prepare_crosswalk(
               ctx.schedule.id,
               :qgenda,
               [row(ctx.iris, "Old Alias")],
               ctx.admin
             )

    assert {:ok, _} = IdentityMappings.approve_crosswalk(plan, ctx.admin)
    source!(ctx, ctx.juniper, "Old Alias", 1)
    assert {:ok, _} = IdentityMappings.backfill()

    assert {:ok, %{status: :held, reason: :conflicting_observations}} =
             IdentityMappings.resolve(ctx.schedule.id, :qgenda, "Old Alias")
  end

  test "historical prior-name drift is evidence, never a fabricated original identity", ctx do
    source!(ctx, ctx.iris, "Reed, Iris", 1, "Different Historical Person")
    assert {:ok, _} = IdentityMappings.backfill()
    [saved] = mappings()
    assert saved["target_snapshot"]["resident_id"] == ctx.iris.resident_id
    assert saved["evidence_snapshot"]["previous_name"] == "Different Historical Person"

    assert {:ok, %{status: :held, reason: :historical_drift}} =
             IdentityMappings.resolve(ctx.schedule.id, :qgenda, "Reed, Iris")

    assert {:ok, plan} =
             IdentityMappings.prepare_crosswalk(
               ctx.schedule.id,
               :qgenda,
               [row(ctx.iris, "Reed, Iris")],
               ctx.admin
             )

    assert plan.summary.held == 1
    assert {:error, :held} = IdentityMappings.approve_crosswalk(plan, ctx.admin)
  end

  test "removed membership stays held even when its position is reused", ctx do
    approve!(ctx, "Alias")
    [saved] = mappings()
    Repo.query!("DELETE FROM schedule_residents WHERE id = $1", [ctx.iris.id])

    {:ok, _} =
      Residents.insert_resident(ctx.schedule.id, %{
        name: "Replacement Person",
        position_code: "R2-1",
        residency_year: 2,
        schedule_number: 1
      })

    [retained] = mappings()
    assert retained["scope_schedule_id"] == ctx.schedule.id
    assert is_nil(retained["schedule_resident_id"])
    assert retained["target_snapshot"] == saved["target_snapshot"]

    assert {:ok, %{status: :held, reason: :target_unavailable}} =
             IdentityMappings.resolve(ctx.schedule.id, :csv, "Alias")
  end

  test "in-place person reassignment or rename cannot silently change an approved identity",
       ctx do
    approve!(ctx, "Alias")

    Repo.query!("UPDATE residents SET name = 'Renamed Person' WHERE id = $1", [
      ctx.iris.resident_id
    ])

    assert {:ok, %{status: :held, reason: :target_changed}} =
             IdentityMappings.resolve(ctx.schedule.id, :csv, "Alias")

    Repo.query!("UPDATE residents SET name = 'Iris Reed' WHERE id = $1", [ctx.iris.resident_id])

    replacement =
      Repo.insert!(%Residents.Resident{
        name: "Another Person",
        calendar_token: Ecto.UUID.generate()
      })

    Repo.query!("UPDATE schedule_residents SET resident_id = $1 WHERE id = $2", [
      replacement.id,
      ctx.iris.id
    ])

    assert {:ok, %{status: :held, reason: :target_changed}} =
             IdentityMappings.resolve(ctx.schedule.id, :csv, "Alias")
  end

  test "inconsistent historical batch scope is rejected without rewriting source rows", ctx do
    source = source!(ctx, ctx.iris, "Alias", 1)
    {:ok, other} = Schedules.upsert_schedule(2025, "2025–2026")

    Repo.query!("UPDATE detailed_import_batches SET schedule_id = $1 WHERE id = $2", [
      other.id,
      source.batch_id
    ])

    before = source_facts()
    assert {:error, :inconsistent_source_scope} = IdentityMappings.backfill(batch_size: 1)
    assert mappings() == []
    assert source_facts() == before
  end

  test "CSV replacement, builder save, and year deletion preserve held history", ctx do
    csv = ",Dates,2032-07-05\n,,2032-07-09\n,,Events\nR1-1,Iris Reed,GYN\n"
    assert {:ok, _, _} = ScheduleImporter.import_csv(csv)
    schedule = Repo.get_by!(Schedule, academic_year: 2032)
    [person] = Residents.list_residents_for_schedule(schedule.id)
    csv_ctx = %{ctx | schedule: schedule, iris: person}
    approve!(csv_ctx, "CSV Legacy")
    [original] = mappings()
    assert {:ok, _, _} = ScheduleImporter.import_csv(csv)
    assert {:ok, %{status: :held}} = IdentityMappings.resolve(schedule.id, :csv, "CSV Legacy")
    assert {:ok, state} = ScheduleBuilder.generate(2032)
    assert {:ok, _} = ScheduleBuilder.save(state)
    assert {:ok, _} = Schedules.delete_schedule(schedule.id)
    [retained] = mappings()
    assert retained["target_snapshot"] == original["target_snapshot"]
    assert retained["scope_schedule_id"] == schedule.id
    assert is_nil(retained["schedule_id"])
  end

  test "database prevents a mapping from pointing to membership in another schedule", ctx do
    approve!(ctx, "Alias")
    {:ok, other} = Schedules.upsert_schedule(2025, "2025–2026")

    assert_raise Postgrex.Error, fn ->
      Repo.query!("UPDATE source_identity_mappings SET schedule_id = $1", [other.id],
        mode: :savepoint
      )
    end

    assert {:ok, %{status: :matched}} = IdentityMappings.resolve(ctx.schedule.id, :csv, "Alias")
  end

  test "database rejects two current approved mappings for the same scoped alias", ctx do
    approve!(ctx, "Alias")

    error =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          """
          INSERT INTO source_identity_mappings
          SELECT (jsonb_populate_record(NULL::source_identity_mappings,
            to_jsonb(m) || jsonb_build_object('id', -100, 'revision', m.revision + 1))).*
          FROM source_identity_mappings m
          """,
          [],
          mode: :savepoint
        )
      end

    assert error.postgres.code == :unique_violation
    assert length(mappings()) == 1
  end

  test "direct database schedule deletion nulls live references and preserves review evidence",
       ctx do
    approve!(ctx, "Alias")
    [saved] = mappings()
    Repo.query!("DELETE FROM schedules WHERE id = $1", [ctx.schedule.id])
    [retained] = mappings()
    assert is_nil(retained["schedule_id"])
    assert is_nil(retained["schedule_resident_id"])

    immutable = [
      "scope_schedule_id",
      "target_snapshot",
      "revision",
      "approved_by_id",
      "actor_snapshot",
      "evidence_snapshot",
      "source_key",
      "lookup_key",
      "inserted_at"
    ]

    assert Map.take(retained, immutable) == Map.take(saved, immutable)
  end

  test "new independent exact-name evidence cannot silently lose to an approved alias", ctx do
    approve!(ctx, "New Exact Person")

    {:ok, _} =
      Residents.insert_resident(ctx.schedule.id, %{
        name: "New Exact Person",
        position_code: "R2-4",
        residency_year: 2,
        schedule_number: 4
      })

    assert {:ok, result} = IdentityMappings.resolve(ctx.schedule.id, :csv, "New Exact Person")
    assert result.status in [:held, :ambiguous]
    assert is_nil(result.schedule_resident_id)
  end

  test "fresh explicit review can replace an unavailable approval with a new immutable revision",
       ctx do
    approve!(ctx, "Alias")
    [original] = mappings()
    Repo.query!("DELETE FROM schedule_residents WHERE id = $1", [ctx.iris.id])

    {:ok, replacement} =
      Residents.insert_resident(ctx.schedule.id, %{
        name: "Replacement Person",
        position_code: "R2-1",
        residency_year: 2,
        schedule_number: 1
      })

    assert {:ok, plan} =
             IdentityMappings.prepare_crosswalk(
               ctx.schedule.id,
               :csv,
               [row(replacement, "Alias")],
               ctx.admin
             )

    assert plan.summary.held == 0

    assert {:ok, %{approved: 1, unchanged: 0}} =
             IdentityMappings.approve_crosswalk(plan, ctx.admin)

    [retired, current] = mappings()
    refute retired["current"]
    assert retired["target_snapshot"] == original["target_snapshot"]
    assert retired["revision"] == original["revision"]
    assert current["current"]
    assert current["revision"] > original["revision"]
    assert current["target_snapshot"]["schedule_resident_id"] == replacement.id

    assert {:ok, %{status: :matched, schedule_resident_id: id}} =
             IdentityMappings.resolve(ctx.schedule.id, :csv, "Alias")

    assert id == replacement.id
  end

  test "tampered prepared rows are rejected without writing a mapping", ctx do
    assert {:ok, plan} = prepare(ctx, "Alias")
    tampered = Map.put(plan, :rows, [row(ctx.juniper, "Alias")])
    assert {:error, reason} = IdentityMappings.approve_crosswalk(tampered, ctx.admin)
    assert reason in [:invalid_plan, :stale_plan]
    assert mappings() == []
  end

  defp row(person, key),
    do: %{source_key: key, position_code: person.position_code, expected_name: person.name}

  defp prepare(ctx, key),
    do: IdentityMappings.prepare_crosswalk(ctx.schedule.id, :csv, [row(ctx.iris, key)], ctx.admin)

  defp approve!(ctx, key) do
    {:ok, plan} = prepare(ctx, key)
    {:ok, _} = IdentityMappings.approve_crosswalk(plan, ctx.admin)
  end

  defp mappings,
    do:
      Repo.query!("SELECT to_jsonb(m) FROM source_identity_mappings m ORDER BY id").rows
      |> List.flatten()

  defp source_facts do
    for table <- [
          "detailed_import_batches",
          "detailed_activities",
          "detailed_activity_sources",
          "residents",
          "schedule_residents"
        ] do
      {table, Repo.query!("SELECT to_jsonb(t) FROM #{table} t ORDER BY id").rows}
    end
  end

  defp source!(ctx, person, key, n, previous_name \\ nil) do
    batch =
      Repo.insert!(%ImportBatch{
        schedule_id: ctx.schedule.id,
        created_by_id: ctx.admin.id,
        fingerprint: "identity-#{n}",
        header_start: ~D[2026-12-28],
        header_end: ~D[2027-01-03]
      })

    activity =
      Repo.get_by(Activity,
        schedule_resident_id: person.id,
        date: ~D[2026-12-29],
        raw_task: "Clinic PM",
        period: "PM",
        site: "SMH"
      ) ||
        Repo.insert!(%Activity{
          schedule_resident_id: person.id,
          date: ~D[2026-12-29],
          raw_task: "Clinic PM",
          period: "PM",
          site: "SMH"
        })

    Repo.insert!(%ActivitySource{
      activity_id: activity.id,
      batch_id: batch.id,
      source_sheet: "December",
      source_cell: "D#{n}",
      raw_staff: key,
      display_name: person.name,
      previous_name: previous_name || person.name,
      notes: [%{"text" => "Retain note"}],
      source_reference: %{"sheet" => "December", "cell" => "D#{n}"}
    })
  end
end
