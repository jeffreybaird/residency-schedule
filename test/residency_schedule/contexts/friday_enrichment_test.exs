defmodule ResidencySchedule.TaskMappings.FridayEnrichmentTest do
  use ResidencySchedule.DataCase

  alias ResidencySchedule.DetailedSchedules.ActivitySource
  alias ResidencySchedule.EffectiveSchedule
  alias ResidencySchedule.EffectiveScheduleV2Fixtures, as: F
  alias ResidencySchedule.FridayEnrichmentFixtures, as: Fixtures
  alias ResidencySchedule.ShiftOverrides
  alias ResidencySchedule.TaskMappings

  alias ResidencySchedule.TaskMappings.{
    Classification,
    FridayEnrichment,
    FridayPolicyAttestation,
    Mapping
  }

  @contacts for rank <- ~w(1st 2nd 3rd 4th), do: "SMH Obstetrics Resident #{rank} Contact Night"
  @friday ~D[2026-11-06]
  @targets ["night_float", "strong_weekend_nights"]

  test "empty preview is explicit, aggregate and read-only without implicit seeding" do
    assert {:ok, plan} = FridayEnrichment.preview()
    assert plan.scope.kind == :historical_friday_policy
    assert plan.scope.version == 1
    assert plan.scope.max_classification_id == 0
    assert plan.scope.schedule_id == nil
    assert byte_size(plan.scope.policy_fingerprint) == 64
    assert Enum.all?(Map.values(plan.counts), &(&1 == 0))
    assert Repo.all(Mapping) == []
  end

  test "four exact historical contact labels qualify on any date while gynecology stays generic" do
    first = Fixtures.historical_source(hd(@contacts), @friday)

    for {label, n} <- Enum.with_index(tl(@contacts), 1),
        do: Fixtures.add_historical_source(first, label, Date.add(@friday, n))

    Fixtures.add_historical_source(first, hd(@contacts), Date.add(@friday, 4))

    Fixtures.add_historical_source(
      first,
      "SMH Gynecology Chief On Call Night",
      Date.add(@friday, 5)
    )

    Fixtures.add_historical_source(
      first,
      "SMH Gynecology Intern On Call Night",
      Date.add(@friday, 6)
    )

    before = historical_rows()

    assert {:ok, plan} = FridayEnrichment.preview(batch_size: 2)
    assert plan.counts.scanned == 7
    assert plan.counts.eligible == 5
    assert plan.counts.not_applicable == 2
    assert plan.counts.held == 0
    assert plan.counts.conflicting == 0
    assert historical_rows() == before
    assert Repo.all(FridayPolicyAttestation) == []

    assert Repo.aggregate(
             from(m in Mapping, where: m.rule_version == "legacy_task_classification_v2"),
             :count
           ) == 0
  end

  test "bounded apply preserves every original row, records bound evidence and repeats with zero additions" do
    ctx = Fixtures.historical_source()
    Fixtures.add_historical_source(ctx, Enum.at(@contacts, 1), Date.add(@friday, 1))
    before = historical_rows()
    assert {:ok, plan} = FridayEnrichment.preview()

    assert {:ok, %{scanned: 2, attested: 2, unchanged: 0}} =
             FridayEnrichment.apply(plan.scope, batch_size: 1)

    assert historical_rows() == before
    saved = Repo.all(FridayPolicyAttestation)
    assert length(saved) == 2

    for row <- saved do
      class = Repo.get!(Classification, row.classification_id)
      assert row.original_source_id == class.original_source_id
      assert row.original_input_digest == class.input_digest
      assert row.original_mapping_id == class.mapping_id
      assert row.original_mapping_revision == class.mapping_revision
      assert row.original_rule_version == "legacy_task_classification_v1"
      assert row.namespace == "qgenda"
      assert row.rule_version == "legacy_task_classification_v2"
      assert row.policy == "friday_strong_correction_v1"
      assert row.status == "context_required"
      assert row.target_codes == @targets
      assert row.evidence_origin == "legacy_code"
      assert row.policy_fingerprint == plan.scope.policy_fingerprint
    end

    assert {:ok, %{attested: 0, unchanged: 2}} = FridayEnrichment.apply(plan.scope)
    assert {:ok, %{counts: %{eligible: 0, unchanged: 2}}} = FridayEnrichment.preview()
    assert Repo.all(FridayPolicyAttestation) == saved
    assert historical_rows() == before
  end

  test "scope cutoff excludes later classifications and schedule scope excludes other rosters" do
    ctx = Fixtures.historical_source()
    other_member = F.member(2027, 2)

    other_class =
      Fixtures.add_historical_source(%{member: other_member}, hd(@contacts), ~D[2027-11-05])

    assert {:ok, plan} = FridayEnrichment.preview(schedule_id: ctx.member.schedule_id)
    assert other_class.classification.id <= plan.scope.max_classification_id
    later = Fixtures.add_historical_source(ctx, hd(@contacts), Date.add(@friday, 1))
    assert later.classification.id > plan.scope.max_classification_id
    assert {:ok, %{scanned: 1, attested: 1}} = FridayEnrichment.apply(plan.scope)

    assert Enum.map(Repo.all(FridayPolicyAttestation), & &1.classification_id) == [
             ctx.classification.id
           ]

    other = F.member(2028, 3)
    assert {:ok, empty} = FridayEnrichment.preview(schedule_id: other.schedule_id)
    assert empty.counts.scanned == 0
    assert {:ok, %{attested: 0}} = FridayEnrichment.apply(empty.scope)
  end

  test "closed options and scope validation reject unreviewed policy changes without writes" do
    Fixtures.historical_source()
    assert {:ok, plan} = FridayEnrichment.preview()

    for options <- [
          [batch_size: 0],
          [batch_size: 1001],
          [batch_size: "1"],
          [schedule_id: -1],
          [unknown: 1],
          :bad
        ] do
      assert {:error, _} = FridayEnrichment.preview(options)
    end

    for scope <- [
          Map.put(plan.scope, :version, 2),
          Map.put(plan.scope, :kind, :other),
          Map.put(plan.scope, :max_classification_id, -1),
          Map.put(plan.scope, :policy_fingerprint, "unreviewed"),
          Map.put(plan.scope, :unknown, true),
          %{}
        ] do
      assert {:error, _} = FridayEnrichment.apply(scope)
    end

    assert {:error, _} = FridayEnrichment.apply(plan.scope, schedule_id: 2026)
    assert Repo.all(FridayPolicyAttestation) == []
  end

  test "apply revalidates changed source facts instead of trusting preview counts" do
    ctx = Fixtures.historical_source()
    assert {:ok, plan} = FridayEnrichment.preview()
    Repo.update!(Ecto.Changeset.change(ctx.source, notes: [%{"text" => "Changed after preview"}]))

    assert {:ok, %{attested: 0, conflicting: 1}} =
             FridayEnrichment.apply(plan.scope, batch_size: 1)

    assert Repo.all(FridayPolicyAttestation) == []
    assert Repo.get!(Classification, ctx.classification.id) == ctx.classification
  end

  test "full current graph drift and invalid retained digests are conflicting at write time" do
    first = Fixtures.historical_source()
    second = Fixtures.add_historical_source(first, Enum.at(@contacts, 1), Date.add(@friday, 1))
    third = Fixtures.add_historical_source(first, Enum.at(@contacts, 2), Date.add(@friday, 2))
    Repo.update!(Ecto.Changeset.change(first.batch, fingerprint: "changed fingerprint"))
    Repo.update!(Ecto.Changeset.change(second.source, source_reference: %{"changed" => true}))

    Repo.update!(
      Ecto.Changeset.change(third.classification, input_digest: String.duplicate("0", 64))
    )

    assert {:ok, %{counts: %{eligible: 0, conflicting: 3}}} = FridayEnrichment.preview()
    assert Repo.all(FridayPolicyAttestation) == []
  end

  test "write validation covers member, person, schedule, literal activity and original mapping facts" do
    ctx = Fixtures.historical_source()

    for {record, changes} <- [
          {ctx.member, %{position_code: "R2-9"}},
          {ctx.graph.resident, %{name: "Changed synthetic identity"}},
          {ctx.schedule, %{academic_year: 2028}},
          {ctx.activity, %{period: "Night"}},
          {ctx.activity, %{raw_task: "SMH Gynecology Chief On Call Night"}},
          {ctx.source, %{raw_staff: "Changed source identity"}},
          {ctx.mapping, %{policy: "unsupported_policy"}},
          {ctx.classification, %{mapping_snapshot: %{}}}
        ] do
      schema = record.__struct__
      Repo.update!(Ecto.Changeset.change(record, changes))
      assert {:ok, %{counts: %{eligible: 0, conflicting: 1}}} = FridayEnrichment.preview()
      fresh = Repo.get!(schema, record.id)
      Repo.update!(Ecto.Changeset.change(fresh, Map.take(record, Map.keys(changes))))
    end
  end

  test "protected original classifications and current mappings are never enriched" do
    first = Fixtures.historical_source()
    second = Fixtures.add_historical_source(first, Enum.at(@contacts, 1), Date.add(@friday, 1))
    third = Fixtures.add_historical_source(first, Enum.at(@contacts, 2), Date.add(@friday, 2))
    Repo.update!(Ecto.Changeset.change(first.classification, evidence_origin: "reviewed"))
    Repo.update!(Ecto.Changeset.change(second.mapping, evidence_origin: "custom"))
    Repo.update!(Ecto.Changeset.change(third.mapping, current: false))

    custom =
      Map.from_struct(third.mapping)
      |> Map.drop([:id, :__meta__, :inserted_at, :updated_at])
      |> Map.merge(%{revision: 2, current: true, evidence_origin: "custom"})

    Repo.insert!(struct!(Mapping, custom))
    assert {:ok, plan} = FridayEnrichment.preview()
    assert plan.counts.protected == 3
    assert {:ok, %{attested: 0, protected: 3}} = FridayEnrichment.apply(plan.scope)
    assert Repo.all(FridayPolicyAttestation) == []
  end

  test "missing source graphs are held and canonical v1 to v2 seeding does not rewrite originals" do
    ctx = Fixtures.historical_source()
    F.rotation(ctx.member, "ambulatory", @friday, @friday)
    assert {:ok, plan} = FridayEnrichment.preview()
    assert {:ok, %{attested: 1}} = FridayEnrichment.apply(plan.scope)
    assert duty_codes(ctx.member, @friday) == ["strong_weekend_nights"]
    original = Repo.get!(Classification, ctx.classification.id)
    assert {:ok, _} = TaskMappings.seed_legacy()
    assert {:ok, %{counts: %{unchanged: 1}}} = FridayEnrichment.preview()
    assert duty_codes(ctx.member, @friday) == ["strong_weekend_nights"]
    assert Repo.get!(Classification, original.id) == original
    Repo.delete!(ctx.source)
    assert {:ok, %{counts: %{held: 1}}} = FridayEnrichment.preview()
    assert length(Repo.all(FridayPolicyAttestation)) == 1
  end

  test "database binds one attestation to exactly its original classification and fixed semantics" do
    ctx = Fixtures.historical_source()
    assert {:ok, plan} = FridayEnrichment.preview()
    assert {:ok, %{attested: 1}} = FridayEnrichment.apply(plan.scope)
    other = Fixtures.add_historical_source(ctx, Enum.at(@contacts, 1), Date.add(@friday, 1))
    [row] = Repo.all(FridayPolicyAttestation)

    for {column, value} <- [
          {"classification_id", other.classification.id},
          {"original_source_id", other.source.id},
          {"original_mapping_id", other.mapping.id},
          {"original_mapping_revision", row.original_mapping_revision + 1},
          {"original_input_digest", String.duplicate("0", 64)},
          {"policy", "rotation_context_v1"},
          {"evidence_origin", "reviewed"},
          {"status", "resolved"}
        ] do
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          "UPDATE friday_policy_attestations SET #{column}=$1 WHERE id=$2",
          [value, row.id],
          mode: :savepoint
        )
      end
    end

    assert_raise Postgrex.Error, fn ->
      Repo.query!(
        "UPDATE friday_policy_attestations SET target_codes=ARRAY['night_float'] WHERE id=$1",
        [row.id],
        mode: :savepoint
      )
    end

    columns =
      "classification_id,original_source_id,original_input_digest,original_mapping_id,namespace,original_mapping_revision,original_rule_version,policy_fingerprint,policy,rule_version,status,target_codes,evidence_origin,original_semantics,source_anchor,mapping_anchor,inserted_at,updated_at"

    duplicate =
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          "INSERT INTO friday_policy_attestations (#{columns}) SELECT #{columns} FROM friday_policy_attestations WHERE id=$1",
          [row.id],
          mode: :savepoint
        )
      end

    assert duplicate.postgres.code == :unique_violation

    assert_raise Postgrex.Error, fn ->
      Repo.query!(
        "DELETE FROM activity_source_classifications WHERE id=$1",
        [ctx.classification.id],
        mode: :savepoint
      )
    end
  end

  test "source and year removal preserve attestation history without blocking normal deletion" do
    ctx = Fixtures.historical_source()
    assert {:ok, plan} = FridayEnrichment.preview()
    assert {:ok, %{attested: 1}} = FridayEnrichment.apply(plan.scope)
    saved = Repo.all(FridayPolicyAttestation)
    Repo.delete!(ctx.source)
    Repo.delete!(ctx.activity)
    Repo.delete!(ctx.batch)
    assert {:ok, _} = ResidencySchedule.Schedules.delete_schedule(ctx.member.schedule_id)
    assert Repo.all(FridayPolicyAttestation) == saved
    assert Repo.get!(Classification, ctx.classification.id).activity_source_id == nil
  end

  test "reusing a deleted source ID cannot reactivate an attestation whose live class link was nulled" do
    ctx = Fixtures.historical_source()
    F.rotation(ctx.member, "ambulatory", @friday, @friday)
    assert {:ok, plan} = FridayEnrichment.preview()
    assert {:ok, %{attested: 1}} = FridayEnrichment.apply(plan.scope)
    saved = Repo.all(FridayPolicyAttestation)
    Repo.delete!(ctx.source)
    fields = Map.take(ctx.source, ActivitySource.__schema__(:fields))
    Repo.insert!(struct!(ActivitySource, fields))
    assert Repo.get!(Classification, ctx.classification.id).activity_source_id == nil
    assert duty_codes(ctx.member, @friday) == ["ambulatory"]

    assert {:ok, diagnostics} =
             EffectiveSchedule.evidence_diagnostics(ctx.member.schedule_id, :v2)

    assert F.diagnostic(ctx, :invalid_friday_policy_attestation) in diagnostics
    assert Repo.all(FridayPolicyAttestation) == saved
  end

  test "attested history enables Friday correction and peer post-call without changing legacy reads" do
    ctx = Fixtures.historical_source()
    F.rotation(ctx.member, "ambulatory", @friday, @friday)
    peer = F.member(2026, 2)
    F.rotation(peer, "night_float", @friday, @friday)
    legacy = EffectiveSchedule.for_schedule(ctx.member.schedule_id, :legacy)
    assert "ambulatory" in duty_codes(ctx.member, @friday)
    refute "strong_weekend_nights" in duty_codes(ctx.member, @friday)
    assert {:ok, plan} = FridayEnrichment.preview()
    assert {:ok, %{attested: 1}} = FridayEnrichment.apply(plan.scope)
    assert duty_codes(ctx.member, @friday) == ["strong_weekend_nights"]
    assert duty_codes(peer, @friday) == ["post_call"]
    assert duty_codes(ctx.member, @friday) == duty_codes(ctx.member, @friday, :legacy)
    assert duty_codes(peer, @friday) == duty_codes(peer, @friday, :legacy)

    assert EffectiveSchedule.calendar_events(ctx.member.resident_id, :v2) ==
             EffectiveSchedule.calendar_events(ctx.member.resident_id, :legacy)

    assert EffectiveSchedule.for_schedule(ctx.member.schedule_id, :legacy) == legacy

    assert {:ok, diagnostics} =
             EffectiveSchedule.evidence_diagnostics(ctx.member.schedule_id, :v2)

    refute Enum.any?(diagnostics, &(&1.reason == :invalid_friday_policy_attestation))
  end

  test "coverage and non-Friday dates remain protected after attestation" do
    ctx = Fixtures.historical_source()
    saturday = Fixtures.add_historical_source(ctx, Enum.at(@contacts, 1), Date.add(@friday, 1))
    rotation = F.rotation(ctx.member, "ambulatory", @friday, Date.add(@friday, 1))
    cover = F.member(2026, 2)

    assert {:ok, _} =
             ShiftOverrides.create_override(%{
               rotation_id: rotation.id,
               covering_schedule_resident_id: cover.id,
               override_start_date: @friday,
               override_end_date: @friday
             })

    assert {:ok, plan} = FridayEnrichment.preview()
    assert {:ok, %{attested: 2}} = FridayEnrichment.apply(plan.scope)
    assert duty_codes(ctx.member, @friday) == ["ambulatory"]
    assert duty_codes(cover, @friday) == ["ambulatory"]
    assert "ambulatory" in duty_codes(saturday.member, Date.add(@friday, 1))
    refute "strong_weekend_nights" in duty_codes(saturday.member, Date.add(@friday, 1))
  end

  test "changed attested anchors exclude only the affected occurrence and emit a bounded diagnostic" do
    ctx = Fixtures.historical_source()
    F.rotation(ctx.member, "ambulatory", @friday, @friday)
    assert {:ok, plan} = FridayEnrichment.preview()
    assert {:ok, %{attested: 1}} = FridayEnrichment.apply(plan.scope)
    Repo.update!(Ecto.Changeset.change(ctx.activity, raw_task: "Renamed after attestation"))
    assert duty_codes(ctx.member, @friday) == ["ambulatory"]

    assert {:ok, diagnostics} =
             EffectiveSchedule.evidence_diagnostics(ctx.member.schedule_id, :v2)

    assert Enum.filter(diagnostics, &(&1.reason == :invalid_friday_policy_attestation)) == [
             F.diagnostic(ctx, :invalid_friday_policy_attestation)
           ]
  end

  test "a later protected classification or current mapping invalidates an attestation without mutating it" do
    ctx = Fixtures.historical_source()
    F.rotation(ctx.member, "ambulatory", @friday, @friday)
    assert {:ok, plan} = FridayEnrichment.preview()
    assert {:ok, %{attested: 1}} = FridayEnrichment.apply(plan.scope)
    saved = Repo.all(FridayPolicyAttestation)

    for {record, origin} <- [{ctx.classification, "reviewed"}, {ctx.mapping, "custom"}] do
      Repo.update!(Ecto.Changeset.change(record, evidence_origin: origin))

      assert Repo.get!(Classification, ctx.classification.id).input_digest ==
               ctx.classification.input_digest

      assert duty_codes(ctx.member, @friday) == ["ambulatory"]

      assert {:ok, diagnostics} =
               EffectiveSchedule.evidence_diagnostics(ctx.member.schedule_id, :v2)

      assert F.diagnostic(ctx, :invalid_friday_policy_attestation) in diagnostics
      assert Repo.all(FridayPolicyAttestation) == saved

      Repo.update!(
        Ecto.Changeset.change(Repo.get!(record.__struct__, record.id),
          evidence_origin: "legacy_code"
        )
      )
    end
  end

  test "changed actual targets on the bound old mapping invalidate an attestation after canonical reseeding" do
    ctx = Fixtures.historical_source()
    F.rotation(ctx.member, "ambulatory", @friday, @friday)
    assert {:ok, plan} = FridayEnrichment.preview()
    assert {:ok, %{attested: 1}} = FridayEnrichment.apply(plan.scope)
    assert {:ok, _} = TaskMappings.seed_legacy()

    Repo.query!(
      "INSERT INTO source_task_mapping_targets (mapping_id,activity_type_code) VALUES ($1,'ultrasound')",
      [ctx.mapping.id]
    )

    assert duty_codes(ctx.member, @friday) == ["ambulatory"]

    assert {:ok, diagnostics} =
             EffectiveSchedule.evidence_diagnostics(ctx.member.schedule_id, :v2)

    assert F.diagnostic(ctx, :invalid_friday_policy_attestation) in diagnostics
  end

  test "tampered attestation anchors are diagnosed without falling back to label inference" do
    ctx = Fixtures.historical_source()
    F.rotation(ctx.member, "ambulatory", @friday, @friday)
    assert {:ok, plan} = FridayEnrichment.preview()
    assert {:ok, %{attested: 1}} = FridayEnrichment.apply(plan.scope)
    [attestation] = Repo.all(FridayPolicyAttestation)
    Repo.update!(Ecto.Changeset.change(attestation, source_anchor: %{}))
    assert duty_codes(ctx.member, @friday) == ["ambulatory"]

    assert {:ok, diagnostics} =
             EffectiveSchedule.evidence_diagnostics(ctx.member.schedule_id, :v2)

    assert F.diagnostic(ctx, :invalid_friday_policy_attestation) in diagnostics
  end

  test "read-time integrity deliberately excludes large notes while write-time checking retains them" do
    ctx = Fixtures.historical_source()
    F.rotation(ctx.member, "ambulatory", @friday, @friday)
    assert {:ok, plan} = FridayEnrichment.preview()
    assert {:ok, %{attested: 1}} = FridayEnrichment.apply(plan.scope)

    Repo.update!(
      Ecto.Changeset.change(ctx.source,
        notes: [%{"text" => String.duplicate("Large retained note", 1000)}]
      )
    )

    assert duty_codes(ctx.member, @friday) == ["strong_weekend_nights"]
    assert {:ok, %{counts: %{conflicting: 1}}} = FridayEnrichment.preview()
  end

  test "V2 loads attestation anchors in one batch without fetching historical source snapshots" do
    ctx = Fixtures.historical_source()
    F.rotation(ctx.member, "ambulatory", @friday, Date.add(@friday, 15))
    assert {:ok, plan} = FridayEnrichment.preview()
    assert {:ok, %{attested: 1}} = FridayEnrichment.apply(plan.scope)
    one = read_queries(ctx.member.schedule_id)

    for n <- 1..9, do: Fixtures.add_historical_source(ctx, hd(@contacts), Date.add(@friday, n))
    assert {:ok, expanded} = FridayEnrichment.preview()
    assert {:ok, %{attested: 9}} = FridayEnrichment.apply(expanded.scope)
    many = read_queries(ctx.member.schedule_id)
    assert length(many) == length(one)
    assert Enum.count(many, &String.contains?(&1.query, "friday_policy_attestations")) == 1
    refute Enum.any?(many, &Enum.member?(&1.columns, "source_snapshot"))
  end

  test "release wrappers preview and apply reviewed scope without seeding a newer catalogue" do
    Fixtures.historical_source()
    assert {:ok, plan} = ResidencySchedule.Release.preview_friday_policy_enrichment()
    assert plan.counts.eligible == 1
    assert Repo.all(FridayPolicyAttestation) == []

    assert {:ok, %{attested: 1}} =
             ResidencySchedule.Release.apply_friday_policy_enrichment(plan.scope)

    assert Repo.aggregate(
             from(m in Mapping, where: m.rule_version == "legacy_task_classification_v2"),
             :count
           ) == 0
  end

  test "a failed SQL page rolls back only that page and retries preserve prior committed work" do
    ctx = Fixtures.historical_source()
    second = Fixtures.add_historical_source(ctx, Enum.at(@contacts, 1), Date.add(@friday, 1))
    third = Fixtures.add_historical_source(ctx, Enum.at(@contacts, 2), Date.add(@friday, 2))
    assert {:ok, plan} = FridayEnrichment.preview()

    Repo.query!(
      "CREATE FUNCTION pg_temp.reject_friday_probe() RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN IF NEW.classification_id=#{third.classification.id} THEN RAISE EXCEPTION 'synthetic attestation write failure'; END IF; RETURN NEW; END; $$"
    )

    Repo.query!(
      "CREATE TRIGGER reject_friday_probe BEFORE INSERT ON friday_policy_attestations FOR EACH ROW EXECUTE FUNCTION pg_temp.reject_friday_probe()"
    )

    try do
      assert {:error, :write_failed} = FridayEnrichment.apply(plan.scope, batch_size: 2)

      assert Enum.sort(Enum.map(Repo.all(FridayPolicyAttestation), & &1.classification_id)) ==
               Enum.sort([ctx.classification.id, second.classification.id])
    after
      Repo.query!("DROP TRIGGER reject_friday_probe ON friday_policy_attestations")
    end

    assert {:ok, %{attested: 1, unchanged: 2}} = FridayEnrichment.apply(plan.scope, batch_size: 2)
  end

  defp duty_codes(member, date, version \\ :v2) do
    {:ok, rows} = EffectiveSchedule.for_person(member.resident_id, version)

    rows
    |> Enum.filter(&(&1.date == date))
    |> Enum.flat_map(& &1.duties)
    |> Enum.map(& &1.code)
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp historical_rows do
    Map.new(
      ~w(activity_types source_task_mappings source_task_mapping_targets activity_source_classifications detailed_activity_sources detailed_activities detailed_import_batches schedule_residents residents schedules source_identity_mappings),
      fn table ->
        {table, Repo.query!("SELECT to_jsonb(t) FROM #{table} t ORDER BY to_jsonb(t)::text").rows}
      end
    )
  end

  defp read_queries(schedule_id) do
    id = {__MODULE__, make_ref()}
    owner = self()

    :ok =
      :telemetry.attach(
        id,
        [:residency_schedule, :repo, :query],
        fn _event, _measurements, metadata, pid ->
          if self() == pid do
            columns = query_columns(metadata.result)

            send(pid, {:friday_enrichment_query, %{query: metadata.query, columns: columns}})
          end
        end,
        owner
      )

    try do
      assert {:ok, _} = EffectiveSchedule.for_schedule(schedule_id, :v2)
      collect_queries([])
    after
      :telemetry.detach(id)
    end
  end

  defp collect_queries(acc) do
    receive do
      {:friday_enrichment_query, query} -> collect_queries([query | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp query_columns({:ok, %{columns: columns}}), do: columns || []
  defp query_columns(_result), do: []
end
