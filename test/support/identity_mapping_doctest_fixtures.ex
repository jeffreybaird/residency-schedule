defmodule ResidencySchedule.IdentityMappingDoctestFixtures do
  @moduledoc "Explicit synthetic fixtures for sandboxed resident identity doctests."

  alias ResidencySchedule.DetailedSchedules.{Activity, ActivitySource, ImportBatch}
  alias ResidencySchedule.Repo
  alias ResidencySchedule.Residents
  alias ResidencySchedule.Schedules
  alias ResidencySchedule.Schedules.Schedule
  import ResidencySchedule.ScheduleFixtures, only: [admin_user: 0]

  def seed do
    year =
      Enum.find(Stream.iterate(2042, &(&1 + 1)), fn year ->
        is_nil(Repo.get_by(Schedule, academic_year: year))
      end)

    {:ok, schedule} = Schedules.upsert_schedule(year, "#{year}–#{year + 1}")

    {:ok, member} =
      Residents.insert_resident(schedule.id, %{
        name: "Iris Reed",
        position_code: "R2-1",
        residency_year: 2,
        schedule_number: 1
      })

    %{
      schedule: schedule,
      member: member,
      admin: admin_user(),
      rows: [%{source_key: "Legacy Iris", position_code: "R2-1", expected_name: "Iris Reed"}]
    }
  end

  def with_source do
    ctx = seed()

    batch =
      Repo.insert!(%ImportBatch{
        schedule_id: ctx.schedule.id,
        created_by_id: ctx.admin.id,
        fingerprint: "identity-doctest-source",
        header_start: Date.new!(ctx.schedule.academic_year, 12, 29),
        header_end: Date.new!(ctx.schedule.academic_year + 1, 1, 4)
      })

    activity =
      Repo.insert!(%Activity{
        schedule_resident_id: ctx.member.id,
        date: Date.new!(ctx.schedule.academic_year, 12, 30),
        raw_task: "Clinic PM",
        period: "PM",
        site: "SMH"
      })

    source =
      Repo.insert!(%ActivitySource{
        activity_id: activity.id,
        batch_id: batch.id,
        source_sheet: "December",
        source_cell: "D6",
        raw_staff: "Legacy Iris",
        display_name: ctx.member.name,
        previous_name: ctx.member.name,
        source_reference: %{"sheet" => "December", "cell" => "D6"}
      })

    Map.put(ctx, :source, source)
  end
end
