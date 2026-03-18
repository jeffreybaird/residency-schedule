defmodule ResidencySchedule.Importer.ScheduleImporter do
  @moduledoc """
  Imports parsed CSV data into the database.

  Strategy: upsert the schedule record for the given academic year,
  then wipe and reload all schedule residents and rotations for that year only.
  Other years are untouched. Resident (person) records are never deleted —
  find_or_create semantics ensure each physical person has exactly one row.
  """

  alias ResidencySchedule.Repo
  alias ResidencySchedule.Importer.CsvParser
  alias ResidencySchedule.Schedules
  alias ResidencySchedule.Residents
  alias ResidencySchedule.Rotations
  alias ResidencySchedule.Residents.ScheduleResident

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
  upserts the schedule, deletes and reloads schedule_residents/rotations for that year.
  Resident (person) records are preserved and reused across re-imports.

  Returns `{:ok, %{schedule_id: id, residents: count, rotations: count}}`.

      iex> ResidencySchedule.Importer.ScheduleImporter.persist([])
      {:error, "No residents or rotations to import"}
  """
  def persist([]), do: {:error, "No residents or rotations to import"}

  def persist(parsed_residents) do
    persist(parsed_residents, derive_academic_year_from_residents(parsed_residents))
  end

  @doc """
  Imports a list of parsed `%CsvParser{}` structs for an explicit academic year.

  Used by the schedule builder so the target year is always the loaded/generated year,
  not re-derived from rotation dates (which can be sparse or empty).

  Returns `{:ok, %{schedule_id: id, residents: count, rotations: count}}`.

      iex> ResidencySchedule.Importer.ScheduleImporter.persist([], 2026)
      {:error, "No residents or rotations to import"}
  """
  def persist([], _academic_year), do: {:error, "No residents or rotations to import"}

  def persist(parsed_residents, academic_year) do
    label = Schedules.academic_year_label(academic_year)

    Repo.transaction(fn ->
      {:ok, schedule} = Schedules.upsert_schedule(academic_year, label)

      Repo.delete_all(from(sr in ScheduleResident, where: sr.schedule_id == ^schedule.id))

      {resident_count, rotation_count} =
        Enum.reduce(parsed_residents, {0, 0}, fn parsed, {r_acc, rot_acc} ->
          {:ok, schedule_resident} =
            Residents.insert_resident(schedule.id, %{
              position_code: parsed.position_code,
              residency_year: parsed.residency_year,
              schedule_number: parsed.schedule_number,
              name: parsed.name
            })

          {:ok, rot_count} = Rotations.insert_rotations(schedule_resident.id, parsed.rotations)
          {r_acc + 1, rot_acc + rot_count}
        end)

      %{schedule_id: schedule.id, residents: resident_count, rotations: rotation_count}
    end)
  end

  defp derive_academic_year_from_residents(parsed_residents) do
    parsed_residents
    |> Enum.flat_map(fn r -> Enum.flat_map(r.rotations, &[&1.start_date, &1.end_date]) end)
    |> CsvParser.derive_academic_year()
  end
end
