defmodule ResidencySchedule.Importer.ScheduleMerger do
  @moduledoc """
  Merges an add-on schedule (e.g. the early summer-float period) onto the tail of
  a base schedule to produce one continuous timeline.

  Base columns whose date range starts on or after the add-on's first date are
  replaced by the add-on's columns; everything earlier in the base (including any
  mid-year float block) is left untouched. Rows are matched by position code, so
  the add-on's rotation cells extend each resident's row in place.

  Where a real (non-empty, non-`FLOAT`) base cell overlaps an add-on date and the
  values disagree, the disagreement is recorded as a conflict and returned to the
  caller. The add-on value wins in the merged output.
  """

  alias ResidencySchedule.Importer.Csv

  @resident_row ~r/^R[1-4]-\d+$/

  @doc """
  Merges `addon_csv` onto the tail of `base_csv`.

  Returns `{:ok, %{csv: binary, conflicts: [conflict]}}`, where each conflict is a
  map with `:position_code`, `:name`, `:date`, `:base`, and `:addon` keys.

      iex> early =
      ...>   "test/fixtures/summer_float.csv"
      ...>   |> File.read!()
      ...>   |> ResidencySchedule.Importer.SummerFloatSplitter.split()
      ...>   |> elem(1)
      ...>   |> Map.fetch!(:early)
      iex> base = File.read!("test/fixtures/schedule_2025_2026.csv")
      iex> {:ok, %{conflicts: conflicts}} = ResidencySchedule.Importer.ScheduleMerger.merge(base, early)
      iex> length(conflicts)
      12
  """
  def merge(base_csv, addon_csv) do
    base = Csv.parse(base_csv)
    addon = Csv.parse(addon_csv)

    [addon_start, addon_end, addon_events | _] = addon
    base_start = Enum.at(base, 0)
    base_end = Enum.at(base, 1)

    addon_dates = date_columns(addon_start)
    cutoff = addon_dates |> Enum.map(&elem(&1, 1)) |> Enum.min(Date)
    addon_indices = Enum.map(addon_dates, &elem(&1, 0))
    keep_indices = keep_indices(base_start, cutoff)
    base_ranges = base_ranges(base_start, base_end)
    addon_by_code = index_by_code(addon)

    case build_rows(
           base,
           keep_indices,
           addon_indices,
           addon_start,
           addon_end,
           addon_events,
           addon_by_code
         ) do
      {:ok, rows} ->
        conflicts = collect_conflicts(base, base_ranges, addon_dates, addon_by_code)
        {:ok, %{csv: Csv.encode(rows), conflicts: conflicts}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Prepends `addon_csv` onto the head of `base_csv`.

  Add-on columns whose date falls before the base's first date are inserted after
  the code/name columns; the base keeps its own columns from its first date
  onward. Overlapping dates where a real base cell disagrees with the add-on are
  returned as conflicts; the base value wins in the merged output.

      iex> late =
      ...>   "test/fixtures/summer_float.csv"
      ...>   |> File.read!()
      ...>   |> ResidencySchedule.Importer.SummerFloatSplitter.split()
      ...>   |> elem(1)
      ...>   |> Map.fetch!(:late)
      iex> base = File.read!("test/fixtures/schedule_2026_2027.csv")
      iex> {:ok, %{conflicts: conflicts}} = ResidencySchedule.Importer.ScheduleMerger.prepend(base, late)
      iex> length(conflicts)
      0
  """
  def prepend(base_csv, addon_csv) do
    base = Csv.parse(base_csv)
    addon = Csv.parse(addon_csv)

    [addon_start, addon_end, addon_events | _] = addon
    base_start = Enum.at(base, 0)
    base_end = Enum.at(base, 1)

    base_first = base_start |> date_columns() |> Enum.map(&elem(&1, 1)) |> Enum.min(Date)
    addon_columns = date_columns(addon_start)
    new_indices = addon_columns |> Enum.filter(&before?(&1, base_first)) |> Enum.map(&elem(&1, 0))
    overlap = Enum.reject(addon_columns, &before?(&1, base_first))
    base_ranges = base_ranges(base_start, base_end)
    addon_by_code = index_by_code(addon)

    case build_prepended_rows(
           base,
           new_indices,
           addon_start,
           addon_end,
           addon_events,
           addon_by_code
         ) do
      {:ok, rows} ->
        conflicts = collect_conflicts(base, base_ranges, overlap, addon_by_code)
        {:ok, %{csv: Csv.encode(rows), conflicts: conflicts}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp before?({_index, date}, cutoff), do: Date.compare(date, cutoff) == :lt

  # --- Row assembly ---

  defp build_prepended_rows(
         base,
         new_indices,
         addon_start,
         addon_end,
         addon_events,
         addon_by_code
       ) do
    base
    |> Enum.with_index()
    |> Enum.map(fn {row, index} ->
      case tail_cells(
             index,
             row,
             new_indices,
             addon_start,
             addon_end,
             addon_events,
             addon_by_code
           ) do
        {:error, reason} -> {:error, reason}
        cells -> {:ok, Enum.take(row, 2) ++ cells ++ Enum.drop(row, 2)}
      end
    end)
    |> collect()
  end

  defp build_rows(
         base,
         keep_indices,
         addon_indices,
         addon_start,
         addon_end,
         addon_events,
         addon_by_code
       ) do
    base
    |> Enum.with_index()
    |> Enum.map(fn {row, index} ->
      kept = slice(row, keep_indices)

      tail =
        tail_cells(index, row, addon_indices, addon_start, addon_end, addon_events, addon_by_code)

      case tail do
        {:error, reason} -> {:error, reason}
        cells -> {:ok, kept ++ cells}
      end
    end)
    |> collect()
  end

  defp tail_cells(0, _row, indices, addon_start, _end, _events, _by_code),
    do: slice(addon_start, indices)

  defp tail_cells(1, _row, indices, _start, addon_end, _events, _by_code),
    do: slice(addon_end, indices)

  defp tail_cells(2, _row, indices, _start, _end, addon_events, _by_code),
    do: slice(addon_events, indices)

  defp tail_cells(_index, row, indices, _start, _end, _events, addon_by_code) do
    code = List.first(row, "")

    if Regex.match?(@resident_row, code) do
      case Map.get(addon_by_code, code) do
        nil -> {:error, {:missing_addon_row, code}}
        addon_row -> slice(addon_row, indices)
      end
    else
      List.duplicate("", length(indices))
    end
  end

  # --- Conflict detection ---

  defp collect_conflicts(base, base_ranges, addon_dates, addon_by_code) do
    base
    |> Enum.filter(&resident_row?/1)
    |> Enum.flat_map(fn row ->
      code = List.first(row, "")
      addon_row = Map.fetch!(addon_by_code, code)
      row_conflicts(code, Enum.at(row, 1, ""), row, addon_row, base_ranges, addon_dates)
    end)
  end

  defp row_conflicts(code, name, base_row, addon_row, base_ranges, addon_dates) do
    Enum.flat_map(addon_dates, fn {addon_index, date} ->
      case containing_range(base_ranges, date) do
        nil ->
          []

        {base_index, _start, _end} ->
          base_value = trimmed(base_row, base_index)
          addon_value = trimmed(addon_row, addon_index)

          build_conflict(code, name, date, base_value, addon_value)
      end
    end)
  end

  defp conflict?(base_value, addon_value) do
    base_value != "" and base_value != "FLOAT" and base_value != addon_value
  end

  defp containing_range(base_ranges, date) do
    Enum.find(base_ranges, fn {_index, start_date, end_date} ->
      Date.compare(start_date, date) != :gt and Date.compare(date, end_date) != :gt
    end)
  end

  # --- Column helpers ---

  defp keep_indices(base_start, cutoff) do
    drop =
      base_start
      |> date_columns()
      |> Enum.filter(&on_or_after?(&1, cutoff))
      |> Enum.map(&elem(&1, 0))

    Enum.to_list(0..(length(base_start) - 1)) -- drop
  end

  defp on_or_after?({_index, date}, cutoff), do: Date.compare(date, cutoff) != :lt

  defp date_columns(row) do
    row
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} ->
      case Date.from_iso8601(value) do
        {:ok, date} -> [{index, date}]
        {:error, _} -> []
      end
    end)
  end

  defp base_ranges(base_start, base_end) do
    Enum.map(date_columns(base_start), fn {index, start_date} ->
      end_date =
        case Date.from_iso8601(Enum.at(base_end, index, "")) do
          {:ok, date} -> date
          {:error, _} -> start_date
        end

      {index, start_date, end_date}
    end)
  end

  defp index_by_code(rows) do
    rows
    |> Enum.filter(&resident_row?/1)
    |> Map.new(fn row -> {List.first(row, ""), row} end)
  end

  defp resident_row?(row), do: row |> List.first("") |> then(&Regex.match?(@resident_row, &1))

  defp slice(row, indices), do: Enum.map(indices, &Enum.at(row, &1, ""))

  defp trimmed(row, index), do: row |> Enum.at(index, "") |> String.trim()

  defp collect(results) do
    Enum.reduce_while(results, {:ok, []}, fn
      {:ok, value}, {:ok, acc} -> {:cont, {:ok, [value | acc]}}
      {:error, reason}, _acc -> {:halt, {:error, reason}}
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_conflict(code, name, date, base_value, addon_value) do
    if conflict?(base_value, addon_value) do
      [%{position_code: code, name: name, date: date, base: base_value, addon: addon_value}]
    else
      []
    end
  end
end
