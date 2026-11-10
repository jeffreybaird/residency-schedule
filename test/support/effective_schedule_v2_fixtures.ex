defmodule ResidencySchedule.EffectiveScheduleV2Fixtures do
  @moduledoc "Synthetic retained Phase 2 evidence for effective-read contracts."

  alias ResidencySchedule.{
    IdentityMappings,
    Repo,
    Residents,
    ScheduleFixtures,
    Schedules,
    TaskMappings,
    Timings
  }

  alias ResidencySchedule.DetailedSchedules.{Activity, ActivitySource, ImportBatch}
  alias ResidencySchedule.Rotations.Rotation
  alias ResidencySchedule.TaskMappings.Classification
  alias ResidencySchedule.Timings.Timing

  @doc "Creates an isolated synthetic membership. Database fixture; exempt from doctest."
  def member(year \\ 2026, number \\ 1) do
    {:ok, schedule} = Schedules.upsert_schedule(year, "#{year}–#{year + 1}")

    {:ok, member} =
      Residents.insert_resident(schedule.id, %{
        name: "Synthetic Resident #{number}",
        position_code: "R2-#{number}",
        residency_year: 2,
        schedule_number: number
      })

    member
  end

  @doc "Creates a stored baseline block. Database fixture; exempt from doctest."
  def rotation(member, type, first, last, slot \\ 0) do
    Repo.insert!(%Rotation{
      schedule_resident_id: member.id,
      rotation_type: type,
      start_date: first,
      end_date: last,
      slot_index: slot
    })
  end

  @doc "Creates one literal source occurrence. Database fixture; exempt from doctest."
  def source(member, date, task, period \\ nil) do
    activity =
      Repo.insert!(%Activity{
        schedule_resident_id: member.id,
        date: date,
        raw_task: task,
        period: period
      })

    add_source(member, activity)
  end

  @doc "Adds another retained occurrence of an activity. Database fixture; exempt from doctest."
  def add_source(member, activity) do
    batch =
      Repo.insert!(%ImportBatch{
        schedule_id: member.schedule_id,
        created_by_id: ScheduleFixtures.admin_user().id,
        fingerprint: Ecto.UUID.generate(),
        header_start: activity.date,
        header_end: activity.date
      })

    source =
      Repo.insert!(%ActivitySource{
        activity_id: activity.id,
        batch_id: batch.id,
        raw_staff: "Source Alias #{member.id}",
        display_name: member.name,
        previous_name: member.name,
        source_sheet: "Synthetic",
        source_cell: "A1"
      })

    %{member: member, activity: activity, source: source}
  end

  @doc "Explicitly backfills and approves synthetic evidence before reads. Exempt from doctest."
  def retain(sources, approve \\ true) do
    {:ok, _} = TaskMappings.seed_legacy()
    {:ok, _} = TaskMappings.backfill()
    {:ok, _} = Timings.backfill()
    {:ok, _} = IdentityMappings.backfill()
    admin = ScheduleFixtures.admin_user()

    sources
    |> Enum.uniq_by(&{&1.member.id, &1.source.raw_staff})
    |> Enum.filter(fn _ -> approve end)
    |> Enum.each(fn %{member: member, source: source} ->
      rows = [
        %{
          source_key: source.raw_staff,
          position_code: member.position_code,
          expected_name: member.name
        }
      ]

      {:ok, plan} = IdentityMappings.prepare_crosswalk(member.schedule_id, :qgenda, rows, admin)
      {:ok, _} = IdentityMappings.approve_crosswalk(plan, admin)
    end)

    sources
  end

  @doc "Returns one retained classification. Database fixture; exempt from doctest."
  def classification(source),
    do: Repo.get_by!(Classification, original_source_id: source.source.id)

  @doc "Returns one retained timing. Database fixture; exempt from doctest."
  def timing(source), do: Repo.get_by!(Timing, original_source_id: source.source.id)

  @doc "Retains an actual v1 contact-night occurrence before enriching the catalogue. Database fixture; exempt from doctest."
  def retain_historical_contact(source) do
    alias ResidencySchedule.TaskMappings.{ActivityType, Mapping, Target}
    codes = ["night_float", "strong_weekend_nights"]

    for code <- codes do
      label = ResidencySchedule.Rotations.rotation_type_label(code)
      Repo.insert!(%ActivityType{code: code, label: label, description: label})
    end

    facts = %{
      namespace: "qgenda",
      source_label: source.activity.raw_task,
      lookup_key: source.activity.raw_task,
      normalization_version: "qgenda_exact_v1",
      recognized: true,
      evidence_origin: "legacy_code",
      rule_version: "legacy_task_classification_v1",
      policy: "rotation_context_v1"
    }

    snapshot =
      facts
      |> Map.put(:targets, codes)
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

    mapping =
      Repo.insert!(
        struct!(
          Mapping,
          Map.merge(facts, %{revision: 1, current: true, evidence_snapshot: snapshot})
        )
      )

    for code <- codes, do: Repo.insert!(%Target{mapping_id: mapping.id, activity_type_code: code})
    {:ok, %{processed: 1}} = TaskMappings.backfill()
    retain([source])
  end

  @doc """
  Builds the exact public diagnostic for an occurrence.

      iex> source = %{member: %{id: 2}, activity: %{id: 3, date: ~D[2026-11-03]}, source: %{id: 4}}
      iex> ResidencySchedule.EffectiveScheduleV2Fixtures.diagnostic(source, :missing_timing)
      %{reason: :missing_timing, activity_id: 3, activity_source_id: 4, schedule_resident_id: 2, date: ~D[2026-11-03]}
  """
  def diagnostic(source, reason) do
    %{
      reason: reason,
      activity_id: source.activity.id,
      activity_source_id: source.source.id,
      schedule_resident_id: source.member.id,
      date: source.activity.date
    }
  end
end
