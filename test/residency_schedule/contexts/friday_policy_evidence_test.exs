defmodule ResidencySchedule.FridayPolicyEvidenceTest do
  use ResidencySchedule.DataCase

  alias ResidencySchedule.Importer.QgendaPreview
  alias ResidencySchedule.Rotations
  alias ResidencySchedule.TaskMappingDoctestFixtures, as: Fixtures
  alias ResidencySchedule.TaskMappings
  alias ResidencySchedule.TaskMappings.{ActivityType, Classification, Mapping, Target}

  @contacts for rank <- ~w(1st 2nd 3rd 4th),
                do: "SMH Obstetrics Resident #{rank} Contact Night"
  @targets ["night_float", "strong_weekend_nights"]
  @v1 "legacy_task_classification_v1"
  @v2 "legacy_task_classification_v2"
  @policy "friday_strong_correction_v1"

  test "only the four QGenda contact-night mappings gain explicit Friday policy evidence" do
    assert {:ok, _} = TaskMappings.seed_legacy()

    enriched = Repo.all(from m in Mapping, where: m.rule_version == ^@v2 or m.policy == ^@policy)
    assert Enum.sort(Enum.map(enriched, & &1.source_label)) == Enum.sort(@contacts)

    for label <- @contacts do
      assert {:ok, result} = TaskMappings.classify(:qgenda, label)
      assert result.status == :context_required
      assert result.activity_type_code == nil
      assert result.target_codes == @targets
      assert result.namespace == "qgenda"
      assert result.rule_version == @v2
      assert result.policy == @policy
      assert result.mapping_revision == 1
    end

    for label <- ["SMH Gynecology Chief On Call Night", "SMH Gynecology Intern On Call Night"] do
      assert {:ok, result} = TaskMappings.classify(:qgenda, label)
      assert result.status == :context_required
      assert result.target_codes == @targets
      assert result.rule_version == @v1
      assert result.policy == "rotation_context_v1"
    end

    catalogue = mapping_rows()
    assert {:ok, %{mappings_added: 0, conflicting: 0}} = TaskMappings.seed_legacy()
    assert mapping_rows() == catalogue
  end

  test "seeding appends contact revisions while preserving valid v1 mappings and retained occurrences" do
    old_mappings = seed_historical_contacts()
    ctx = Fixtures.source(hd(@contacts))

    assert {:ok, %{status: :context_required, rule_version: @v1, policy: "rotation_context_v1"}} =
             TaskMappings.classify(:qgenda, hd(@contacts))

    assert {:ok, %{processed: 1, context_required: 1, conflicting: 0}} = TaskMappings.backfill()
    old_occurrences = Repo.all(Classification)
    old_targets = Repo.all(from t in Target, order_by: [t.mapping_id, t.activity_type_code])
    original_activity = Repo.get!(ResidencySchedule.DetailedSchedules.Activity, ctx.activity.id)

    assert {:ok, _} = TaskMappings.seed_legacy()

    for old <- old_mappings do
      retired = Repo.get!(Mapping, old.id)
      assert retired.current == false

      assert Map.drop(Map.from_struct(retired), [:current, :updated_at]) ==
               Map.drop(Map.from_struct(old), [:current, :updated_at])

      current =
        Repo.get_by!(Mapping, namespace: "qgenda", source_label: old.source_label, current: true)

      assert current.id != old.id
      assert current.revision == 2
      assert current.rule_version == @v2
      assert current.policy == @policy
      assert current.evidence_snapshot["policy"] == @policy
      assert current.evidence_snapshot["rule_version"] == @v2
      assert targets(current.id) == @targets
      assert targets(old.id) == @targets
    end

    ids = Enum.map(old_mappings, & &1.id)

    assert Repo.all(
             from t in Target,
               where: t.mapping_id in ^ids,
               order_by: [t.mapping_id, t.activity_type_code]
           ) == old_targets

    assert Repo.all(Classification) == old_occurrences
    assert {:ok, %{processed: 0, conflicting: 1, unchanged: 0}} = TaskMappings.backfill()
    assert Repo.all(Classification) == old_occurrences

    new = Fixtures.add_source(ctx, hd(@contacts), activity: ctx.activity)
    assert {:ok, %{processed: 1, context_required: 1, conflicting: 1}} = TaskMappings.backfill()
    saved = Repo.get_by!(Classification, original_source_id: new.source.id)
    assert saved.rule_version == @v2
    assert saved.status == "context_required"
    assert saved.activity_type_code == nil
    assert saved.mapping_snapshot["policy"] == @policy
    assert saved.mapping_snapshot["target_codes"] == @targets
    assert Repo.get!(Classification, hd(old_occurrences).id) == hd(old_occurrences)

    assert Repo.get!(ResidencySchedule.DetailedSchedules.Activity, ctx.activity.id) ==
             original_activity

    before_repeat = mapping_rows()
    assert {:ok, %{mappings_added: 0}} = TaskMappings.seed_legacy()
    assert mapping_rows() == before_repeat
    assert {:ok, %{processed: 0, unchanged: 1, conflicting: 1}} = TaskMappings.backfill()
  end

  test "new Friday metadata requires its supported version, namespace, policy and exact targets" do
    assert {:ok, _} = TaskMappings.seed_legacy()

    mapping =
      Repo.get_by!(Mapping, namespace: "qgenda", source_label: hd(@contacts), current: true)

    for changes <- [
          %{rule_version: @v1, policy: @policy},
          %{rule_version: @v2, policy: "rotation_context_v1"},
          %{rule_version: "unsupported_v3", policy: @policy}
        ] do
      update_with_snapshot(mapping, changes)

      assert {:ok, %{status: :conflicting, activity_type_code: nil}} =
               TaskMappings.classify(:qgenda, hd(@contacts))
    end

    update_with_snapshot(mapping, %{})

    Repo.delete_all(
      from t in Target,
        where: t.mapping_id == ^mapping.id and t.activity_type_code == "night_float"
    )

    update_with_snapshot(mapping, %{}, ["strong_weekend_nights"])

    assert {:ok, %{status: :conflicting, activity_type_code: nil}} =
             TaskMappings.classify(:qgenda, hd(@contacts))

    Repo.insert!(%Target{mapping_id: mapping.id, activity_type_code: "night_float"})
    {:ok, key} = TaskMappings.normalize_key(:csv, hd(@contacts))

    update_with_snapshot(
      mapping,
      %{
        namespace: "csv",
        lookup_key: key.lookup_key,
        normalization_version: key.normalization_version
      },
      @targets
    )

    assert {:ok, %{status: :conflicting, activity_type_code: nil}} =
             TaskMappings.classify(:csv, hd(@contacts))
  end

  test "tampering legacy Friday evidence cannot produce a classification" do
    Fixtures.source(hd(@contacts))
    assert {:ok, _} = TaskMappings.seed_legacy()

    mapping =
      Repo.get_by!(Mapping, namespace: "qgenda", source_label: hd(@contacts), current: true)

    mapping |> Ecto.Changeset.change(recognized: not mapping.recognized) |> Repo.update!()

    assert {:ok, %{status: :conflicting, activity_type_code: nil}} =
             TaskMappings.classify(:qgenda, hd(@contacts))

    assert {:ok, %{processed: 0, conflicting: 1}} = TaskMappings.backfill()
    assert Repo.all(Classification) == []
  end

  test "enrichment preserves a custom contact-night mapping instead of overwriting it" do
    [mapping | _] = seed_historical_contacts()
    custom = mapping |> Ecto.Changeset.change(evidence_origin: "custom") |> Repo.update!()
    assert {:ok, %{conflicting: 1}} = TaskMappings.seed_legacy()
    assert Repo.get!(Mapping, mapping.id) == custom

    assert Repo.get_by!(Mapping,
             namespace: "qgenda",
             source_label: mapping.source_label,
             current: true
           ).id == mapping.id
  end

  defp seed_historical_contacts do
    for code <- @targets do
      label = Rotations.rotation_type_label(code)
      Repo.insert!(%ActivityType{code: code, label: label, description: label})
    end

    Enum.map(@contacts, fn label ->
      facts = %{
        namespace: "qgenda",
        source_label: label,
        lookup_key: label,
        normalization_version: "qgenda_exact_v1",
        recognized: label in QgendaPreview.known_tasks(),
        evidence_origin: "legacy_code",
        rule_version: @v1,
        policy: "rotation_context_v1"
      }

      mapping =
        Repo.insert!(
          struct!(
            Mapping,
            Map.merge(facts, %{
              revision: 1,
              current: true,
              evidence_snapshot: snapshot(facts, @targets)
            })
          )
        )

      for code <- @targets,
          do: Repo.insert!(%Target{mapping_id: mapping.id, activity_type_code: code})

      mapping
    end)
  end

  defp update_with_snapshot(mapping, changes, codes \\ @targets) do
    fields =
      Map.take(mapping, [
        :namespace,
        :source_label,
        :lookup_key,
        :normalization_version,
        :recognized,
        :evidence_origin,
        :rule_version,
        :policy
      ])
      |> Map.merge(changes)

    Mapping
    |> Repo.get!(mapping.id)
    |> Ecto.Changeset.change(Map.put(fields, :evidence_snapshot, snapshot(fields, codes)))
    |> Repo.update!()
  end

  defp snapshot(fields, codes),
    do:
      fields
      |> Map.put(:targets, codes)
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

  defp targets(id),
    do:
      Repo.all(
        from t in Target,
          where: t.mapping_id == ^id,
          order_by: t.activity_type_code,
          select: t.activity_type_code
      )

  defp mapping_rows,
    do: Repo.all(from m in Mapping, order_by: m.id)
end
