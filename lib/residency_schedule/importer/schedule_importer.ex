defmodule ResidencySchedule.Importer.ScheduleImporter do
  @moduledoc """
  Imports parsed CSV data into the database.

  Strategy: upsert the schedule record for the given academic year,
  then wipe and reload all residents and rotations for that year only.
  Other years are untouched.
  """

  alias ResidencySchedule.Repo
  alias ResidencySchedule.Importer.CsvParser
  alias ResidencySchedule.Schedules
  alias ResidencySchedule.Residents
  alias ResidencySchedule.Rotations
  alias ResidencySchedule.Residents.Resident

  import Ecto.Query

  @doc """
  Full pipeline: accepts a CSV binary, parses it, and persists to the database.

  Returns `{:ok, %{residents: count, rotations: count}, warnings}` on success,
  or `{:error, reason}` on failure.

      iex> ResidencySchedule.Importer.ScheduleImporter.import_csv("")
      {:error, _}
  """
  def import_csv(csv_binary) do
    with {:ok, parsed_residents, warnings} <- CsvParser.parse(csv_binary),
         {:ok, result} <- persist(parsed_residents) do
      {:ok, result, warnings}
    end
  end

  @doc """
  Imports a list of parsed `%CsvParser{}` structs into the database.

  Derives the academic year from the earliest date across all residents' rotations,
  upserts the schedule, deletes and reloads residents/rotations for that year.

  Returns `{:ok, %{schedule_id: id, residents: count, rotations: count}}`.

      iex> ResidencySchedule.Importer.ScheduleImporter.persist([])
      {:error, "No residents or rotations to import"}
  """
  def persist([]) do
    {:error, "No residents or rotations to import"}
  end

  def persist(parsed_residents) do
    academic_year = derive_academic_year_from_residents(parsed_residents)
    label = Schedules.academic_year_label(academic_year)

    Repo.transaction(fn ->
      {:ok, schedule} = Schedules.upsert_schedule(academic_year, label)

      Repo.delete_all(from(r in Resident, where: r.schedule_id == ^schedule.id))

      {resident_count, rotation_count} =
        Enum.reduce(parsed_residents, {0, 0}, fn parsed, {r_acc, rot_acc} ->
          {:ok, resident} =
            Residents.insert_resident(schedule.id, %{
              position_code: parsed.position_code,
              residency_year: parsed.residency_year,
              schedule_number: parsed.schedule_number,
              name: parsed.name
            })

          {:ok, rot_count} = Rotations.insert_rotations(resident.id, parsed.rotations)
          {r_acc + 1, rot_acc + rot_count}
        end)

      %{schedule_id: schedule.id, residents: resident_count, rotations: rotation_count}
    end)
  end

  defp derive_academic_year_from_residents(parsed_residents) do
    all_dates =
      Enum.flat_map(parsed_residents, fn r ->
        Enum.flat_map(r.rotations, &[&1.start_date, &1.end_date])
      end)

    CsvParser.derive_academic_year(all_dates)
  end
end
