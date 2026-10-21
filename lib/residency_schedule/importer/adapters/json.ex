defmodule ResidencySchedule.Importer.Adapters.Json do
  @moduledoc """
  Bounded, preview-only adapter for literal dated activities.

  Input has an integer `academic_year` and a nonempty `assignments` array.
  Assignments require ISO `date`, `raw_staff` and `raw_task` strings, with
  optional string-list `notes` and string `source_sheet`/`source_cell` metadata.
  Optional `header_dates` preserves dates without assignments. Top-level `notes`
  and `unlinked_notes` contain objects with `text` and optional source metadata;
  these standalone notes remain unlinked for review. Unknown keys are ignored.
  No uploaded string becomes an atom, and no persistence route is enabled.
  """
  @behaviour ResidencySchedule.Importer.Adapter

  alias ResidencySchedule.Importer.ImportDocument

  @error "The JSON activity document is invalid or exceeds the preview limits."
  @limit 10_000

  @doc """
  Parses literal activity input into a partial preview-only document.

  Literal assignments retain their notes and source coordinates. Dates become
  `Date` values, missing coordinates receive defaults, and the partial scope
  identifies the source's people and dates without enabling writes.

      iex> json = Jason.encode!(%{
      ...>   academic_year: 2026,
      ...>   assignments: [%{date: "2026-12-28", raw_staff: "Iris Reed", raw_task: "Clinic", notes: ["Bring kit"]}]
      ...> })
      iex> {:ok, document} = ResidencySchedule.Importer.Adapters.Json.parse(json, [])
      iex> document
      %ResidencySchedule.Importer.ImportDocument{
        source: :json,
        kind: :activities,
        academic_year: 2026,
        residents: [],
        assignments: [
          %{
            date: ~D[2026-12-28],
            raw_staff: "Iris Reed",
            raw_task: "Clinic",
            notes: ["Bring kit"],
            source_sheet: "JSON",
            source_cell: "entry-1"
          }
        ],
        header_dates: [~D[2026-12-28]],
        notes: [],
        unlinked_notes: [],
        warnings: [],
        scope: %{
          completeness: :partial,
          record_kinds: [:activities],
          people: ["Iris Reed"],
          dates: [~D[2026-12-28]]
        },
        preview_only: true
      }
  """
  @impl true
  def parse(binary, options) when is_binary(binary) and byte_size(binary) <= 5_000_000 do
    with :preview <- Keyword.get(options, :mode, :preview),
         {:ok, payload} when is_map(payload) <- Jason.decode(binary),
         {:ok, year} <- validate_year(payload, options),
         {:ok, assignments} <- parse_assignments(Map.get(payload, "assignments")),
         {:ok, dates} <-
           parse_dates(Map.get(payload, "header_dates", assignment_dates(assignments))),
         {:ok, notes} <- parse_notes(Map.get(payload, "notes", [])),
         {:ok, unlinked} <- parse_notes(Map.get(payload, "unlinked_notes", [])) do
      {:ok,
       document(
         year,
         assignments,
         include_assignment_dates(dates, assignments),
         Enum.uniq(notes ++ unlinked)
       )}
    else
      _ -> {:error, @error}
    end
  end

  def parse(_binary, _options), do: {:error, @error}

  defp validate_year(payload, options) do
    year = Map.get(payload, "academic_year")

    if is_integer(year) and year in 1..9998 and
         Keyword.get(options, :academic_year, year) == year,
       do: {:ok, year},
       else: {:error, @error}
  end

  defp parse_assignments(values) when is_list(values) and length(values) in 1..@limit do
    values
    |> Enum.with_index(1)
    |> collect(&parse_assignment/1)
  end

  defp parse_assignments(_values), do: {:error, @error}

  defp parse_assignment({value, index}) when is_map(value) do
    with {:ok, date} <- parse_date(Map.get(value, "date")),
         {:ok, staff} <- parse_text(Map.get(value, "raw_staff")),
         {:ok, task} <- parse_text(Map.get(value, "raw_task")),
         true <- String.trim(task) != "",
         {:ok, notes} <- parse_strings(Map.get(value, "notes", [])),
         {:ok, source} <- parse_source(value, "entry-#{index}") do
      {:ok, Map.merge(source, %{date: date, raw_staff: staff, raw_task: task, notes: notes})}
    else
      _ -> {:error, @error}
    end
  end

  defp parse_assignment(_value), do: {:error, @error}

  defp parse_dates(values) when is_list(values) and length(values) <= @limit do
    with {:ok, dates} <- collect(values, &parse_date/1) do
      {:ok, dates |> Enum.uniq() |> Enum.sort(Date)}
    end
  end

  defp parse_dates(_values), do: {:error, @error}

  defp parse_date(%Date{} = value), do: {:ok, value}
  defp parse_date(value) when is_binary(value), do: Date.from_iso8601(value)
  defp parse_date(_value), do: {:error, @error}

  defp parse_notes(values) when is_list(values) and length(values) <= @limit,
    do: values |> Enum.with_index(1) |> collect(&parse_note/1)

  defp parse_notes(_values), do: {:error, @error}

  defp parse_note({value, index}) when is_map(value) do
    with {:ok, text} <- parse_text(Map.get(value, "text")),
         {:ok, source} <- parse_source(value, "note-#{index}") do
      {:ok, Map.merge(source, %{text: text, body: text, assignment_key: nil})}
    end
  end

  defp parse_note(_value), do: {:error, @error}

  defp parse_source(value, default_cell) do
    with {:ok, sheet} <- parse_text(Map.get(value, "source_sheet", "JSON")),
         {:ok, cell} <- parse_text(Map.get(value, "source_cell", default_cell)) do
      {:ok, %{source_sheet: sheet, source_cell: cell}}
    end
  end

  defp parse_text(value) when is_binary(value), do: {:ok, value}
  defp parse_text(_value), do: {:error, @error}

  defp parse_strings(values) when is_list(values) and length(values) <= @limit,
    do: collect(values, &parse_text/1)

  defp parse_strings(_values), do: {:error, @error}

  defp collect(values, parser) do
    values
    |> Enum.reduce_while({:ok, []}, fn value, {:ok, acc} ->
      case parser.(value) do
        {:ok, parsed} -> {:cont, {:ok, [parsed | acc]}}
        {:error, _reason} -> {:halt, {:error, @error}}
      end
    end)
    |> case do
      {:ok, parsed} -> {:ok, Enum.reverse(parsed)}
      error -> error
    end
  end

  defp assignment_dates(assignments), do: Enum.map(assignments, & &1.date)

  defp include_assignment_dates(dates, assignments) do
    dates
    |> Enum.concat(assignment_dates(assignments))
    |> Enum.uniq()
    |> Enum.sort(Date)
  end

  defp document(year, assignments, dates, notes) do
    %ImportDocument{
      source: :json,
      kind: :activities,
      academic_year: year,
      assignments: assignments,
      header_dates: dates,
      notes: notes,
      unlinked_notes: notes,
      preview_only: true,
      scope: %{
        completeness: :partial,
        record_kinds: [:activities],
        dates: dates,
        people: assignments |> Enum.map(& &1.raw_staff) |> Enum.uniq()
      }
    }
  end
end
