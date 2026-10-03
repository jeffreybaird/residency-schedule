defmodule ResidencySchedule.Importer.QgendaParser do
  @moduledoc "Extracts literal calendar assignments and their source notes."
  alias ResidencySchedule.Importer.QgendaWorkbook

  @months ~w(January February March April May June July August September October November December)
  @columns ~w(A C E G I K M)
  @tasks ~w(B D F H J L N)

  @doc """
  Parses calendar pairs, preserving blank staff and simultaneous assignments.

      iex> {:ok, parsed} = ResidencySchedule.Importer.QgendaParser.parse(File.read!("test/fixtures/qgenda/shared.xlsx"))
      iex> hd(parsed.assignments).source_cell
      "B6"
  """
  def parse(binary) do
    with {:ok, sheets} <- QgendaWorkbook.read(binary) do
      parsed =
        Enum.reduce(sheets, %{assignments: [], header_dates: [], notes: []}, fn sheet, acc ->
          state = %{mode: :calendar, dates: %{}, assignments: [], header_dates: [], notes: []}
          result = Enum.reduce(sheet.rows, state, &parse_row(&1, &2, sheet.name))

          %{
            assignments: acc.assignments ++ Enum.reverse(result.assignments),
            header_dates: acc.header_dates ++ result.header_dates,
            notes: acc.notes ++ Enum.reverse(result.notes)
          }
        end)

      if parsed.header_dates == [] do
        {:error, "No QGenda calendar date headers were found."}
      else
        {:ok, link_notes(parsed)}
      end
    end
  rescue
    _ -> {:error, "The QGenda calendar contains invalid dates or cells."}
  end

  defp parse_row(row, state, sheet) do
    values = Map.new(row, fn {reference, text} -> {column(reference), text} end)
    first = Map.get(values, "A", "") |> String.trim()

    cond do
      String.starts_with?(first, "Phone Numbers") or first == "Assignment Tags" ->
        %{state | mode: :ignore}

      state.mode == :ignore ->
        state

      first == "Schedule Notes:" ->
        %{state | mode: :notes}

      state.mode == :notes ->
        collect_note(row, state, sheet)

      true ->
        collect_calendar(row, values, state, sheet)
    end
  end

  defp collect_note(row, state, sheet) do
    notes =
      for {cell, text} <- row, String.trim(text) != "" do
        %{text: text, source_cell: cell, source_sheet: sheet}
      end

    %{state | notes: Enum.reverse(notes) ++ state.notes}
  end

  defp collect_calendar(row, values, state, sheet) do
    dates =
      @columns
      |> Enum.map(&{&1, parse_header(Map.get(values, &1, ""))})
      |> Enum.reject(fn {_, date} -> is_nil(date) end)
      |> Map.new()

    cond do
      map_size(dates) > 0 ->
        %{state | dates: dates, header_dates: Map.values(dates) ++ state.header_dates}

      map_size(state.dates) == 0 ->
        state

      true ->
        collect_assignments(row, values, state, sheet)
    end
  end

  defp collect_assignments(row, values, state, sheet) do
    coordinates = Map.new(row, fn {ref, _} -> {column(ref), ref} end)

    assignments =
      for {staff_col, task_col} <- Enum.zip(@columns, @tasks),
          date = Map.get(state.dates, staff_col),
          not is_nil(date),
          task = Map.get(values, task_col, ""),
          String.trim(task) != "" do
        %{
          date: date,
          raw_staff: Map.get(values, staff_col, ""),
          raw_task: task,
          source_sheet: sheet,
          source_cell: Map.fetch!(coordinates, task_col),
          notes: []
        }
      end

    %{state | assignments: Enum.reverse(assignments) ++ state.assignments}
  end

  defp column(reference) do
    [_, col] = Regex.run(~r/^([A-Z]+)[1-9][0-9]*$/, reference)
    col
  end

  defp parse_header(text) do
    case Regex.run(~r/^(\w+) (\d{1,2}), (\d{4})$/, String.trim(text)) do
      [_, month, day, year] ->
        case Enum.find_index(@months, &(&1 == month)) do
          nil -> nil
          index -> Date.new!(String.to_integer(year), index + 1, String.to_integer(day))
        end

      _ ->
        nil
    end
  end

  defp link_notes(parsed) do
    notes = Enum.map(parsed.notes, &resolve_note(&1, parsed.assignments))

    assignments =
      Enum.map(parsed.assignments, fn assignment ->
        linked = Enum.filter(notes, &(&1.assignment_key == assignment_key(assignment)))
        %{assignment | notes: Enum.map(linked, & &1.body)}
      end)

    %{
      parsed
      | assignments: assignments,
        header_dates: parsed.header_dates |> Enum.uniq() |> Enum.sort(Date),
        notes: notes
    }
    |> Map.put(:unlinked_notes, Enum.filter(notes, &is_nil(&1.assignment_key)))
  end

  defp resolve_note(note, assignments) do
    case Regex.run(~r/^(\d{1,2})\/(\d{1,2})\/(\d{4})\s+\w+\s+(.+)$/s, note.text) do
      [_, month, day, year, remainder] ->
        date =
          Date.new!(String.to_integer(year), String.to_integer(month), String.to_integer(day))

        candidates =
          assignments
          |> Enum.filter(&(&1.date == date and &1.raw_staff != ""))
          |> Enum.map(&{&1, &1.raw_staff <> " " <> &1.raw_task <> " "})
          |> Enum.filter(fn {_, prefix} -> String.starts_with?(remainder, prefix) end)
          |> Enum.sort_by(fn {_, prefix} -> -byte_size(prefix) end)

        case candidates do
          [{assignment, prefix} | _] ->
            Map.merge(note, %{
              assignment_key: assignment_key(assignment),
              body: String.replace_prefix(remainder, prefix, "")
            })

          [] ->
            Map.merge(note, %{assignment_key: nil, body: note.text})
        end

      _ ->
        Map.merge(note, %{assignment_key: nil, body: note.text})
    end
  end

  defp assignment_key(assignment),
    do: {assignment.date, assignment.raw_staff, assignment.raw_task}
end
