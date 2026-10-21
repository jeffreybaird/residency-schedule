defmodule ResidencySchedule.Importer.ScheduleImporter do
  @moduledoc """
  Imports parsed CSV data into the database.

  Strategy: upsert the schedule record for the given academic year,
  then wipe and reload all schedule residents and rotations for that year only.
  Other years are untouched. Resident (person) records are never deleted —
  find_or_create semantics ensure each physical person has exactly one row.
  """

  alias ResidencySchedule.DetailedSchedules
  alias ResidencySchedule.Importer.Adapters.Csv
  alias ResidencySchedule.Importer.CsvParser
  alias ResidencySchedule.Importer.DateUpdater
  alias ResidencySchedule.Importer.ImportDocument
  alias ResidencySchedule.Importer.ResidentLinker
  alias ResidencySchedule.Repo
  alias ResidencySchedule.Residents
  alias ResidencySchedule.Residents.ScheduleResident
  alias ResidencySchedule.Rotations
  alias ResidencySchedule.ScheduleCache.Revision
  alias ResidencySchedule.Schedules

  import Ecto.Query

  @doc """
  Full pipeline: accepts a CSV binary, parses it, and persists to the database.

  Returns `{:ok, %{residents: count, rotations: count}, warnings}` on success,
  or `{:error, reason}` on failure.

      iex> ResidencySchedule.Importer.ScheduleImporter.import_csv("")
      {:error, _}
  """
  def import_csv(csv_binary) do
    with {:ok, document} <- Csv.parse(csv_binary, []),
         {:ok, result} <- persist(document.residents, document.academic_year, source_kind: "csv") do
      {:ok, result, document.warnings}
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
    prepare(csv_binary, [])
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
      {:ok, links} -> persist_linked(parsed_residents, academic_year, links, "csv")
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
    with {:ok, document} <- Csv.parse(csv_binary, options) do
      prepare_document(document, options)
    end
  end

  @doc """
  Reconciles domain roster input without depending on a source parser.
  Database operation; covered by integration tests instead of doctests.
  """
  def prepare_document(%ImportDocument{kind: :rotations} = document, options) do
    case Keyword.get(options, :mode, :replace_year) do
      :replace_year ->
        with :ok <- ensure_replaceable(document.academic_year) do
          {:ok,
           %{
             parsed: document.residents,
             academic_year: document.academic_year,
             proposals: ResidentLinker.propose(document.residents, Residents.list_residents()),
             warnings: document.warnings
           }}
        end

      :update_dates ->
        year = document.academic_year

        with {:ok, prepared} <- DateUpdater.prepare(document.residents, year) do
          {:ok,
           Map.merge(prepared, %{
             parsed: document.residents,
             warnings: document.warnings,
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
  Imports domain resident input into the database. Legacy parser structs remain
  compatible for callers that already hold parsed input.

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
  Imports domain resident input for an explicit academic year.

  Used by the schedule builder so the target year is always the loaded/generated year,
  not re-derived from rotation dates (which can be sparse or empty).

  Returns `{:ok, %{schedule_id: id, residents: count, rotations: count}}`.

      iex> ResidencySchedule.Importer.ScheduleImporter.persist([], 2026)
      {:error, "No residents or rotations to import"}
  """
  def persist([], _academic_year), do: {:error, "No residents or rotations to import"}

  def persist(parsed_residents, academic_year), do: persist(parsed_residents, academic_year, [])

  @doc """
  Persists domain resident input with a known originating writer.

  `:source_kind` accepts `"csv"`, `"builder"`, `"editor"` or `"legacy"`.
  It defaults to `"legacy"` because unannotated callers do not establish origin.
  This metadata does not enable an adapter's write path. Database operation;
  covered by integration tests instead of doctests.
  """
  def persist(parsed_residents, academic_year, options) do
    with {:ok, source_kind} <- source_kind(options) do
      persist_linked(parsed_residents, academic_year, %{}, source_kind)
    end
  end

  defp source_kind(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.all?(Keyword.keys(options), &(&1 == :source_kind)) do
      validate_source_kind(Keyword.get(options, :source_kind, "legacy"))
    else
      {:error, "Choose a known rotation source kind."}
    end
  end

  defp source_kind(_options), do: {:error, "Choose a known rotation source kind."}

  defp validate_source_kind(kind) when kind in ["csv", "builder", "editor", "legacy"],
    do: {:ok, kind}

  defp validate_source_kind(_kind), do: {:error, "Choose a known rotation source kind."}

  # Links map position codes to an existing person id or :new; rows absent
  # from the map fall back to matching an existing person by exact name.
  defp persist_linked([], _academic_year, _links, _source_kind),
    do: {:error, "No residents or rotations to import"}

  defp persist_linked(parsed_residents, academic_year, links, source_kind) do
    label = Schedules.academic_year_label(academic_year)

    Repo.transaction(fn ->
      Revision.lock()
      {:ok, schedule} = Schedules.upsert_schedule(academic_year, label)

      if DetailedSchedules.has_detail?(schedule.id),
        do:
          Repo.rollback(
            "This schedule has saved QGenda detail. Use date updates; whole-year replacement would erase resident links."
          )

      Repo.delete_all(from(sr in ScheduleResident, where: sr.schedule_id == ^schedule.id))

      {resident_count, rotation_count} =
        Enum.reduce(parsed_residents, {0, 0}, fn parsed, {r_acc, rot_acc} ->
          {:ok, schedule_resident} =
            Residents.insert_resident(schedule.id, resident_attrs(parsed, links))

          rotations =
            Enum.map(parsed.rotations, &Map.put(&1, :source_kind, source_kind))

          {:ok, rot_count} = Rotations.insert_rotations(schedule_resident.id, rotations)
          {r_acc + 1, rot_acc + rot_count}
        end)

      %{schedule_id: schedule.id, residents: resident_count, rotations: rotation_count}
    end)
  end

  defp ensure_replaceable(year) do
    case Schedules.get_by_year(year) do
      nil ->
        :ok

      schedule ->
        if DetailedSchedules.has_detail?(schedule.id),
          do:
            {:error,
             "This schedule has saved QGenda detail. Use date updates instead of replacing the year."},
          else: :ok
    end
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

  defp derive_academic_year_from_residents(parsed_residents) do
    parsed_residents
    |> Enum.flat_map(fn r -> Enum.flat_map(r.rotations, &[&1.start_date, &1.end_date]) end)
    |> CsvParser.derive_academic_year()
  end
end
