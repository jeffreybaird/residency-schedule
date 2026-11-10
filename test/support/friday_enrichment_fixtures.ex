defmodule ResidencySchedule.FridayEnrichmentFixtures do
  @moduledoc "Synthetic historical v1 occurrences without seeding the newer catalogue."

  alias ResidencySchedule.DetailedSchedules.ImportBatch
  alias ResidencySchedule.EffectiveScheduleV2Fixtures, as: F
  alias ResidencySchedule.IdentityMappings
  alias ResidencySchedule.Repo
  alias ResidencySchedule.Residents.Resident
  alias ResidencySchedule.Rotations
  alias ResidencySchedule.ScheduleFixtures
  alias ResidencySchedule.Schedules
  alias ResidencySchedule.TaskMappings
  alias ResidencySchedule.TaskMappings.{ActivityType, Classification, Mapping, Target}
  alias ResidencySchedule.Timings

  @targets ["night_float", "strong_weekend_nights"]
  @contact "SMH Obstetrics Resident 1st Contact Night"

  def historical_source(label \\ @contact, date \\ ~D[2026-11-06]) do
    member = F.member()
    add_historical_source(%{member: member}, label, date)
  end

  def add_historical_source(ctx, label, date) do
    mapping = historical_mapping(label)
    source = F.source(ctx.member, date, label)
    {:ok, _} = TaskMappings.backfill()
    {:ok, _} = Timings.backfill()
    admin = ScheduleFixtures.admin_user()

    rows = [
      %{
        source_key: source.source.raw_staff,
        position_code: ctx.member.position_code,
        expected_name: ctx.member.name
      }
    ]

    {:ok, plan} = IdentityMappings.prepare_crosswalk(ctx.member.schedule_id, :qgenda, rows, admin)
    {:ok, _} = IdentityMappings.approve_crosswalk(plan, admin)

    graph = %{
      source: source.source,
      activity: source.activity,
      batch: Repo.get!(ImportBatch, source.source.batch_id),
      member: ctx.member,
      resident: Repo.get!(Resident, ctx.member.resident_id),
      schedule: Repo.get!(Schedules.Schedule, ctx.member.schedule_id)
    }

    Map.merge(source, %{
      classification: Repo.get_by!(Classification, original_source_id: source.source.id),
      mapping: mapping,
      batch: graph.batch,
      schedule: graph.schedule,
      admin: admin,
      graph: graph
    })
  end

  defp historical_mapping(label) do
    case Repo.get_by(Mapping, namespace: "qgenda", source_label: label, current: true) do
      nil -> insert_mapping(label)
      mapping -> mapping
    end
  end

  defp insert_mapping(label) do
    for code <- @targets do
      description = Rotations.rotation_type_label(code)

      Repo.insert!(%ActivityType{code: code, label: description, description: description},
        on_conflict: :nothing,
        conflict_target: :code
      )
    end

    facts = %{
      namespace: "qgenda",
      source_label: label,
      lookup_key: label,
      normalization_version: "qgenda_exact_v1",
      recognized: true,
      evidence_origin: "legacy_code",
      rule_version: "legacy_task_classification_v1",
      policy: "rotation_context_v1"
    }

    snapshot =
      facts
      |> Map.put(:targets, @targets)
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

    mapping =
      Repo.insert!(
        struct!(
          Mapping,
          Map.merge(facts, %{revision: 1, current: true, evidence_snapshot: snapshot})
        )
      )

    for code <- @targets,
        do: Repo.insert!(%Target{mapping_id: mapping.id, activity_type_code: code})

    mapping
  end
end
