defmodule ResidencySchedule.EffectiveSchedule.Inputs do
  @moduledoc "Batched retained inputs for one effective-schedule computation."
  import Ecto.Query
  alias ResidencySchedule.DetailedSchedules.{Activity, ActivitySource, ImportBatch}
  alias ResidencySchedule.IdentityMappings.Mapping
  alias ResidencySchedule.{Repo, Residents, Rotations, ShiftOverrides}
  alias ResidencySchedule.TaskMappings.{Classification, FridayPolicyAttestation, Target}
  alias ResidencySchedule.TaskMappings.Mapping, as: TaskMapping
  alias ResidencySchedule.Timings.Timing

  @task_mapping_fields ~w(id namespace source_label lookup_key normalization_version revision recognized evidence_origin rule_version policy)a

  @doc "Loads local and incoming source schedules once. Database operation; covered by V2PoliciesTest."
  def load(schedule_id) do
    local_overrides = ShiftOverrides.list_overrides_for_schedule(schedule_id)

    schedule_ids =
      [schedule_id | Enum.map(local_overrides, & &1.rotation.schedule_resident.schedule_id)]
      |> Enum.uniq()

    members = Enum.flat_map(schedule_ids, &Residents.list_residents_for_schedule/1)
    member_ids = Enum.map(members, & &1.id)
    members_by_id = Map.new(members, &{&1.id, &1})

    rotations =
      schedule_ids
      |> Enum.flat_map(&Rotations.list_rotations_for_schedule/1)
      |> Enum.map(&%{&1 | schedule_resident: Map.fetch!(members_by_id, &1.schedule_resident_id)})

    overrides =
      schedule_ids
      |> Enum.flat_map(fn id ->
        if id == schedule_id,
          do: local_overrides,
          else: ShiftOverrides.list_overrides_for_schedule(id)
      end)
      |> Enum.uniq_by(& &1.id)

    activities =
      Repo.all(from a in Activity, where: a.schedule_resident_id in ^member_ids, order_by: a.id)

    activity_ids = Enum.map(activities, & &1.id)

    sources =
      Repo.all(
        from s in ActivitySource,
          join: b in ImportBatch,
          on: b.id == s.batch_id,
          where: s.activity_id in ^activity_ids,
          order_by: s.id,
          select:
            {merge(map(s, [:id, :activity_id, :batch_id, :raw_staff]), %{
               batch_schedule_id: b.schedule_id,
               batch_fingerprint: b.fingerprint
             }), b.source_kind}
      )

    source_ids = Enum.map(sources, fn {s, _} -> s.id end)

    classifications =
      Repo.all(
        from c in Classification,
          where: c.original_source_id in ^source_ids,
          select: %{
            id: c.id,
            original_source_id: c.original_source_id,
            activity_source_id: c.activity_source_id,
            input_digest: c.input_digest,
            mapping_id: c.mapping_id,
            mapping_revision: c.mapping_revision,
            evidence_origin: c.evidence_origin,
            status: c.status,
            activity_type_code: c.activity_type_code,
            namespace: c.namespace,
            rule_version: c.rule_version,
            mapping_snapshot:
              fragment(
                "jsonb_build_object('namespace', ?->'namespace', 'rule_version', ?->'rule_version', 'policy', ?->'policy', 'target_codes', ?->'target_codes')",
                c.mapping_snapshot,
                c.mapping_snapshot,
                c.mapping_snapshot,
                c.mapping_snapshot
              )
          }
      )

    timings =
      Repo.all(
        from t in Timing,
          where: t.original_source_id in ^source_ids,
          select:
            map(t, [
              :original_source_id,
              :precision,
              :period,
              :starts_at,
              :ends_at,
              :time_zone,
              :policy,
              :rule_version
            ])
      )

    identities =
      Repo.all(
        from m in Mapping,
          where: m.scope_schedule_id in ^schedule_ids,
          distinct: true,
          select: %{
            scope_schedule_id: m.scope_schedule_id,
            schedule_id: m.schedule_id,
            schedule_resident_id: m.schedule_resident_id,
            namespace: m.namespace,
            lookup_key: m.lookup_key,
            current: m.current,
            status: m.status,
            target_snapshot: m.target_snapshot,
            evidence_snapshot:
              fragment(
                "jsonb_build_object('historical_drift', ?->'historical_drift')",
                m.evidence_snapshot
              )
          }
      )

    %{
      schedule_id: schedule_id,
      members: members,
      members_by_id: members_by_id,
      rotations: rotations,
      overrides: overrides,
      activities: activities,
      sources: Enum.group_by(sources, fn {s, _} -> s.activity_id end),
      classifications: Map.new(classifications, &{&1.original_source_id, &1}),
      friday_attestations: friday_attestations(Enum.map(classifications, & &1.id)),
      timings: Map.new(timings, &{&1.original_source_id, &1}),
      identities: Enum.group_by(identities, &{&1.scope_schedule_id, &1.namespace, &1.lookup_key})
    }
  end

  defp friday_attestations(class_ids) do
    targets =
      from t in Target,
        group_by: t.mapping_id,
        select: %{
          mapping_id: t.mapping_id,
          target_codes:
            fragment("array_agg(? ORDER BY ?)", t.activity_type_code, t.activity_type_code)
        }

    from(a in FridayPolicyAttestation,
      join: old in TaskMapping,
      on: old.id == a.original_mapping_id,
      left_join: old_targets in subquery(targets),
      on: old_targets.mapping_id == old.id,
      left_join: current in TaskMapping,
      on:
        current.namespace == old.namespace and current.lookup_key == old.lookup_key and
          current.current,
      left_join: current_targets in subquery(targets),
      on: current_targets.mapping_id == current.id,
      where: a.classification_id in ^class_ids,
      select: %{
        attestation: a,
        original_mapping:
          merge(map(old, ^@task_mapping_fields), %{
            evidence_snapshot:
              fragment(
                "jsonb_build_object('namespace',?->'namespace','source_label',?->'source_label','lookup_key',?->'lookup_key','normalization_version',?->'normalization_version','recognized',?->'recognized','evidence_origin',?->'evidence_origin','rule_version',?->'rule_version','policy',?->'policy','targets',?->'targets')",
                old.evidence_snapshot,
                old.evidence_snapshot,
                old.evidence_snapshot,
                old.evidence_snapshot,
                old.evidence_snapshot,
                old.evidence_snapshot,
                old.evidence_snapshot,
                old.evidence_snapshot,
                old.evidence_snapshot
              )
          }),
        original_targets: old_targets.target_codes,
        current_mapping:
          merge(map(current, ^@task_mapping_fields), %{
            evidence_snapshot:
              fragment(
                "jsonb_build_object('namespace',?->'namespace','source_label',?->'source_label','lookup_key',?->'lookup_key','normalization_version',?->'normalization_version','recognized',?->'recognized','evidence_origin',?->'evidence_origin','rule_version',?->'rule_version','policy',?->'policy','targets',?->'targets')",
                current.evidence_snapshot,
                current.evidence_snapshot,
                current.evidence_snapshot,
                current.evidence_snapshot,
                current.evidence_snapshot,
                current.evidence_snapshot,
                current.evidence_snapshot,
                current.evidence_snapshot,
                current.evidence_snapshot
              )
          }),
        current_targets: current_targets.target_codes
      }
    )
    |> Repo.all()
    |> Map.new(fn loaded ->
      current = loaded.current_mapping

      loaded =
        if is_nil(current) or is_nil(current.id),
          do: %{loaded | current_mapping: nil},
          else: loaded

      {loaded.attestation.classification_id, loaded}
    end)
  end
end
