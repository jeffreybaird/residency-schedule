defmodule ResidencySchedule.Importer.ScheduleImporter do
  @moduledoc """
  Imports parsed CSV data into the database.

  Strategy: upsert the schedule record for the given academic year,
  then wipe and reload all schedule residents and rotations for that year only.
  Other years are untouched. Resident (person) records are never deleted —
  find_or_create semantics ensure each physical person has exactly one row.
  """

  alias ResidencySchedule.Repo
  alias ResidencySchedule.Importer.DateUpdater
  alias ResidencySchedule.Importer.CsvParser
  alias ResidencySchedule.Importer.ResidentLinker
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
  Parses a CSV and proposes, without writing anything, which existing resident
  (person) each row belongs to. The admin confirms the links, then `commit/3`
  persists them.

  Returns `{:ok, %{parsed: [...], academic_year: year, proposals: [...], warnings: [...]}}`
  or `{:error, reason}`.

      iex> ResidencySchedule.Importer.ScheduleImporter.prepare("")
      {:error, _}
  """
  def prepare(csv_binary) do
    with {:ok, parsed_residents, warnings} <- CsvParser.parse(csv_binary),
         {:ok, academic_year} <- academic_year_of(parsed_residents) do
      {:ok,
       %{
         parsed: parsed_residents,
         academic_year: academic_year,
         proposals: ResidentLinker.propose(parsed_residents, Residents.list_residents()),
         warnings: warnings
       }}
    end
  end

  @doc """
  Persists parsed residents for an academic year using admin-confirmed links:
  a map of position code to an existing person id or `:new`. Links are
  validated against the current people first.

  Returns `{:ok, %{schedule_id: id, residents: count, rotations: count}}` or
  `{:error, reason}`.

      iex> ResidencySchedule.Importer.ScheduleImporter.commit([], 2026, %{})
      {:error, "No residents or rotations to import"}
  """
  def commit([], _academic_year, _links), do: {:error, "No residents or rotations to import"}

  def commit(parsed_residents, academic_year, links) do
    case ResidentLinker.validate(links, parsed_residents, Residents.list_residents()) do
      {:ok, links} -> persist(parsed_residents, academic_year, links)
      {:error, messages} -> {:error, Enum.join(messages, "; ")}
    end
  end

  @doc """
  Imports a CSV using either whole-year replacement or selected date updates.
  Date updates require an existing explicit academic year.
  Exempt from doctest — hits the database.
  """
  def import_csv(csv_binary, options) do
    case Keyword.get(options, :mode, :replace_year) do
      :replace_year ->
        import_csv(csv_binary)

      :update_dates ->
        with {:ok, prepared} <- prepare(csv_binary, options),
             links = ResidentLinker.links_from_params(prepared.proposals, %{}),
             {:ok, result} <- commit(prepared.parsed, prepared.academic_year, links, options) do
          {:ok, result, prepared.warnings}
        end

      _ ->
        {:error, "Unknown import mode"}
    end
  end

  @doc """
  Prepares an import in the requested mode without writing to the database.
  Date updates lock each row to its existing schedule resident identity.
  Exempt from doctest — hits the database.
  """
  def prepare(csv_binary, options) do
    case Keyword.get(options, :mode, :replace_year) do
      :replace_year ->
        prepare(csv_binary)

      :update_dates ->
        year = Keyword.get(options, :academic_year)

        with {:ok, parsed, warnings} <- CsvParser.parse_date_update(csv_binary, year),
             {:ok, prepared} <- DateUpdater.prepare(parsed, year) do
          {:ok,
           Map.merge(prepared, %{
             parsed: parsed,
             warnings: warnings,
             academic_year: year,
             mode: :update_dates
           })}
        end

      _ ->
        {:error, "Unknown import mode"}
    end
  end

  @doc """
  Commits a confirmed import in the requested mode.
  Date updates preserve schedule resident identities and all untouched dates.
  Exempt from doctest — hits the database.
  """
  def commit(parsed, year, links, options) do
    case Keyword.get(options, :mode, :replace_year) do
      :replace_year -> commit(parsed, year, links)
      :update_dates -> DateUpdater.commit(parsed, year, links)
      _ -> {:error, "Unknown import mode"}
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

  def persist(parsed_residents, academic_year), do: persist(parsed_residents, academic_year, %{})

  # Links map position codes to an existing person id or :new; rows absent
  # from the map fall back to matching an existing person by exact name.
  defp persist(parsed_residents, academic_year, links) do
    label = Schedules.academic_year_label(academic_year)

    Repo.transaction(fn ->
      {:ok, schedule} = Schedules.upsert_schedule(academic_year, label)

      Repo.delete_all(from(sr in ScheduleResident, where: sr.schedule_id == ^schedule.id))

      {resident_count, rotation_count} =
        Enum.reduce(parsed_residents, {0, 0}, fn parsed, {r_acc, rot_acc} ->
          {:ok, schedule_resident} =
            Residents.insert_resident(schedule.id, resident_attrs(parsed, links))

          {:ok, rot_count} = Rotations.insert_rotations(schedule_resident.id, parsed.rotations)
          {r_acc + 1, rot_acc + rot_count}
        end)

      %{schedule_id: schedule.id, residents: resident_count, rotations: rotation_count}
    end)
  end

  defp resident_attrs(parsed, links) do
    %{
      position_code: parsed.position_code,
      residency_year: parsed.residency_year,
      schedule_number: parsed.schedule_number,
      name: parsed.name
    }
    |> put_linked_person(Map.get(links, parsed.position_code))
  end

  defp put_linked_person(attrs, person_id) when is_integer(person_id),
    do: Map.put(attrs, :resident_id, person_id)

  defp put_linked_person(attrs, _new_or_unlinked), do: attrs

  defp academic_year_of([]), do: {:error, "No residents or rotations to import"}

  defp academic_year_of(parsed_residents),
    do: {:ok, derive_academic_year_from_residents(parsed_residents)}

  defp derive_academic_year_from_residents(parsed_residents) do
    parsed_residents
    |> Enum.flat_map(fn r -> Enum.flat_map(r.rotations, &[&1.start_date, &1.end_date]) end)
    |> CsvParser.derive_academic_year()
  end
end
