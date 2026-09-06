defmodule ResidencySchedule.ScheduleFixtures do
  @moduledoc """
  Builds a small, deterministic 2026–2027 schedule for context and MCP tests:

  | Resident | Position | Jul 6–Jul 12        | Jul 13–Jul 19       | Jul 20–Jul 26   |
  |----------|----------|---------------------|---------------------|-----------------|
  | Clare    | R2-1     | strong_obstetrics   | ambulatory          | night_float     |
  | Mary     | R2-2     | strong_obstetrics   | strong_obstetrics   | elective        |
  | Tiff     | R3-1     | oncology            | strong_obstetrics   | strong_obstetrics |

  Clare and Mary share Strong OB on Jul 6–12 (7 days). Tiff is on Strong OB
  Jul 13–26.
  """

  alias ResidencySchedule.{Accounts, Residents, Rotations, Schedules}

  @doc """
  Inserts the fixture schedule and returns a map of the schedule and the
  three schedule residents keyed by lowercase first name.
  """
  def seed_mini_schedule do
    {:ok, schedule} = Schedules.upsert_schedule(2026, "2026–2027")

    clare = insert_resident(schedule, "Clare", "R2-1", 2, 1)
    mary = insert_resident(schedule, "Mary", "R2-2", 2, 2)
    tiff = insert_resident(schedule, "Tiff", "R3-1", 3, 1)

    insert_blocks(clare, [:strong_obstetrics, :ambulatory, :night_float])
    insert_blocks(mary, [:strong_obstetrics, :strong_obstetrics, :elective])
    insert_blocks(tiff, [:oncology, :strong_obstetrics, :strong_obstetrics])

    %{schedule: schedule, clare: clare, mary: mary, tiff: tiff}
  end

  @doc """
  Creates an approved resident-role user whose home resident is the given
  schedule resident.
  """
  def resident_user(schedule_resident) do
    {:ok, user} =
      Accounts.create_user(%{
        email:
          "#{String.downcase(schedule_resident.name)}-#{System.unique_integer([:positive])}@urmc.rochester.edu"
      })

    {:ok, user} = Accounts.set_home_resident(user, schedule_resident.id)
    user
  end

  @doc """
  Creates an approved admin user.
  """
  def admin_user do
    {:ok, user} =
      Accounts.create_user(%{
        email: "admin-#{System.unique_integer([:positive])}@urmc.rochester.edu"
      })

    {:ok, admin} = Accounts.set_role(user, :admin)
    admin
  end

  @doc """
  Creates an approved resident-role user with no home resident.
  """
  def unlinked_user do
    {:ok, user} =
      Accounts.create_user(%{
        email: "other-#{System.unique_integer([:positive])}@urmc.rochester.edu"
      })

    user
  end

  @doc """
  Returns the rotation for a schedule resident that contains the date.
  """
  def rotation_on(schedule_resident, date) do
    Rotations.get_rotation_for_resident_on_date(schedule_resident.id, date)
  end

  defp insert_resident(schedule, name, position_code, year, number) do
    {:ok, resident} =
      Residents.insert_resident(schedule.id, %{
        position_code: position_code,
        residency_year: year,
        schedule_number: number,
        name: name
      })

    resident
  end

  defp insert_blocks(resident, types) do
    blocks =
      types
      |> Enum.with_index()
      |> Enum.map(fn {type, idx} ->
        start = Date.add(~D[2026-07-06], idx * 7)

        %{slot_index: idx, start_date: start, end_date: Date.add(start, 6), rotation_type: type}
      end)

    {:ok, _} = Rotations.insert_rotations(resident.id, blocks)
  end
end
