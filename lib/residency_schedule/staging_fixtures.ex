defmodule ResidencySchedule.StagingFixtures do
  @moduledoc "Persistent synthetic data for manual staging deployment rehearsals."

  import Ecto.Query

  alias ResidencySchedule.Accounts.User
  alias ResidencySchedule.DetailedSchedules.{Activity, ActivitySource, ImportBatch}
  alias ResidencySchedule.Repo
  alias ResidencySchedule.Residents.{Resident, ScheduleResident}
  alias ResidencySchedule.Rotations.Rotation
  alias ResidencySchedule.Schedules.Schedule
  alias ResidencySchedule.ShiftOverrides.ShiftOverride

  @years [2025, 2026, 2027]

  @doc """
  Validates the declared environment against the actual connected database.

      iex> ResidencySchedule.StagingFixtures.validate_target("staging", "residency_schedule_staging", "residency_schedule_staging")
      :ok
  """
  def validate_target("staging", "residency_schedule_staging", "residency_schedule_staging"),
    do: :ok

  def validate_target(_, _, _), do: {:error, :not_staging}

  @doc """
  Adds the fixed synthetic rehearsal dataset without resetting existing data.

  Repeated calls retain identities, independently generated feed tokens and manual
  records. Conflicting fixture fields abort the transaction rather than overwrite
  operator changes. Database setup is required; integration tests cover success.
  Use `Release.seed_staging/0` for the guarded operational entry point.
  """
  def seed do
    Repo.transaction(fn ->
      ensure_fixture(
        User,
        %{email: "staging-admin@example.test"},
        %{role: :admin, approved: true, denied: false}
      )

      people = Enum.map(["Stage Briar", "Stage Rowan"], &ensure_person/1)

      appearances =
        Map.new(@years, fn year ->
          schedule = ensure_fixture(Schedule, %{academic_year: year}, %{label: label(year)})
          residents = seed_year(schedule, people)
          {year, residents}
        end)

      seed_coverage(appearances[2025])
      seed_vacation(hd(appearances[2026]))
      %{academic_years: @years, resident_ids: Enum.map(people, & &1.id)}
    end)
  end

  defp label(year), do: "Synthetic staging #{year}–#{year + 1}"

  defp ensure_person(name) do
    case Repo.get_by(Resident, name: name) do
      nil ->
        Repo.insert!(%Resident{name: name, calendar_token: Ecto.UUID.generate()})

      resident ->
        labels = Enum.map(@years, &label/1)

        owned =
          Repo.exists?(
            from sr in ScheduleResident,
              join: s in assoc(sr, :schedule),
              where: sr.resident_id == ^resident.id and s.label in ^labels
          )

        if owned, do: resident, else: Repo.rollback(:fixture_conflict)
    end
  end

  defp seed_year(schedule, people) do
    people
    |> Enum.with_index(1)
    |> Enum.map(fn {person, index} ->
      resident =
        ensure_fixture(
          ScheduleResident,
          %{schedule_id: schedule.id, position_code: "R2-#{index}"},
          %{resident_id: person.id, residency_year: 2, schedule_number: index}
        )

      seed_rotation(resident, 0, "oncology", Date.new!(schedule.academic_year, 7, 1), 7)
      seed_rotation(resident, 1, "night_float", Date.new!(schedule.academic_year, 8, 1), 7)

      seed_activity(
        resident,
        Date.new!(schedule.academic_year, 8, 1),
        "Synthetic overnight duty",
        "Night"
      )

      seed_clinic(resident, schedule.academic_year)

      resident
    end)
  end

  defp seed_clinic(resident, year) do
    for task <- ["Synthetic continuity clinic", "HH GYN ONC R2"] do
      seed_activity(resident, Date.new!(year, 7, 2), task, "Day")
    end
  end

  defp seed_activity(resident, date, task, period) do
    activity =
      ensure_fixture(
        Activity,
        %{schedule_resident_id: resident.id, date: date, raw_task: task},
        %{period: period, site: "Synthetic staging"}
      )

    schedule = Repo.get!(Schedule, resident.schedule_id)
    person = Repo.get!(Resident, resident.resident_id)

    batch =
      ensure_fixture(
        ImportBatch,
        %{schedule_id: schedule.id, fingerprint: "synthetic-staging-activities-v1"},
        %{
          header_start: Date.new!(schedule.academic_year, 7, 1),
          header_end: Date.new!(schedule.academic_year + 1, 6, 30)
        }
      )

    ensure_fixture(
      ActivitySource,
      %{
        batch_id: batch.id,
        source_sheet: "Synthetic staging activities",
        source_cell: "A#{activity.id}"
      },
      %{
        activity_id: activity.id,
        raw_staff: person.name,
        display_name: person.name,
        previous_name: "",
        notes: []
      }
    )
  end

  defp seed_rotation(resident, slot, type, date, days) do
    ensure_fixture(
      Rotation,
      %{schedule_resident_id: resident.id, slot_index: slot},
      %{rotation_type: type, start_date: date, end_date: Date.add(date, days - 1)}
    )
  end

  defp seed_coverage([original, covering]) do
    rotation = Repo.get_by!(Rotation, schedule_resident_id: original.id, slot_index: 0)

    ensure_fixture(
      ShiftOverride,
      %{rotation_id: rotation.id},
      %{
        covering_schedule_resident_id: covering.id,
        override_start_date: ~D[2025-07-03],
        override_end_date: ~D[2025-07-04]
      }
    )
  end

  defp seed_vacation(resident) do
    seed_rotation(resident, 2, "vacation", ~D[2027-04-05], 5)
    seed_rotation(resident, 3, "vacation", ~D[2027-04-12], 5)

    batch =
      ensure_fixture(
        ImportBatch,
        %{schedule_id: resident.schedule_id, fingerprint: "synthetic-staging-vacation-v1"},
        %{header_start: ~D[2027-04-05], header_end: ~D[2027-04-18]}
      )

    [~D[2027-04-10], ~D[2027-04-11], ~D[2027-04-17], ~D[2027-04-18]]
    |> Enum.with_index(1)
    |> Enum.each(fn {date, index} -> seed_vacation_day(resident, batch, date, index) end)
  end

  defp seed_vacation_day(resident, batch, date, index) do
    activity =
      ensure_fixture(
        Activity,
        %{schedule_resident_id: resident.id, date: date, raw_task: "Vacation"},
        %{period: "Day", site: "Synthetic staging"}
      )

    ensure_fixture(
      ActivitySource,
      %{batch_id: batch.id, source_sheet: "Synthetic staging vacation", source_cell: "C#{index}"},
      %{
        activity_id: activity.id,
        raw_staff: "Stage Briar",
        display_name: "Stage Briar",
        previous_name: "",
        notes: [
          %{
            "text" => "Synthetic vacation weekend continuation",
            "source_sheet" => "Synthetic staging vacation",
            "source_cell" => "D#{index}"
          }
        ]
      }
    )
  end

  defp ensure_fixture(schema, identity, attributes) do
    case Repo.get_by(schema, identity) do
      nil ->
        schema |> struct(Map.merge(identity, attributes)) |> Repo.insert!()

      existing ->
        if fixture_matches?(existing, attributes),
          do: existing,
          else: Repo.rollback(:fixture_conflict)
    end
  end

  defp fixture_matches?(existing, attributes) do
    Enum.all?(attributes, fn {key, value} -> Map.fetch!(existing, key) == value end)
  end
end
