defmodule ResidencySchedule.Importer.SummerFloatSplitter do
  @moduledoc """
  Splits the 2026 summer-float transition schedule into two importable CSVs.

  The summer-float file spans the academic-year boundary: the graduating R4s
  work through their last day, then leave, and the new interns start. This module
  divides it at a cutoff date into:

    * an **early** file (dates through the cutoff) rostered as the *outgoing*
      academic year — graduating R4s included, new interns dropped; and
    * a **late** file (dates after the cutoff) rostered as the *incoming*
      academic year — graduating R4s dropped, new interns included.

  Each resident is assigned the position code (`R4-1`, `R3-2`, …) and canonical
  name that `NameNormalizer` records for them in the relevant academic year, and
  rows are ordered to match the other schedule CSVs in `data/`.

  The five row groups in the source (graduating R4s, then the three rising
  classes, then the interns) map to position-code levels differently in each
  file because seniority shifts at the year boundary:

      source group        early (outgoing yr)   late (incoming yr)
      graduating R4s       R4                    (dropped)
      rising R4s           R3                    R4
      rising R3s           R2                    R3
      rising R2s           R1                    R2
      interns              (dropped)             R1
  """

  alias ResidencySchedule.Importer.Csv
  alias ResidencySchedule.Importer.NameNormalizer

  @cutoff ~D[2026-06-17]

  # Source row groups, top to bottom.
  @early_groups [{0, 4}, {1, 3}, {2, 2}, {3, 1}]
  @late_groups [{1, 4}, {2, 3}, {3, 2}, {4, 1}]

  # Float resident names that differ from the canonical first-name form used by
  # `NameNormalizer` and cannot be matched by a shared first token.
  @aliases %{"anne" => "annie", "evdokiya" => "zhenya", "evdokia" => "zhenya"}

  @doc """
  Splits a summer-float CSV binary into `%{early: binary, late: binary}`.

  The cutoff (last date in the early file) defaults to the graduating R4s' last
  day, `2026-06-17`; the following day is the first date in the late file.

      iex> {:ok, %{early: early}} =
      ...>   ResidencySchedule.Importer.SummerFloatSplitter.split(File.read!("test/fixtures/summer_float_sample.csv"))
      iex> early |> String.split("\\n") |> Enum.member?("R3-1,Clare,OB,OFF,OFF,GYN,GYN,OFF")
      true
  """
  def split(binary, cutoff \\ @cutoff) do
    rows = Csv.parse(binary)
    [start_row, end_row, events_row | _] = rows
    blocks = rows |> Enum.drop(3) |> group_blocks()

    early_dates = date_columns(start_row, cutoff, :early)
    late_dates = date_columns(start_row, cutoff, :late)
    early_year = academic_start_year(elem(hd(early_dates), 1))
    late_year = early_year + 1

    with :ok <- ensure_block_count(blocks),
         {:ok, early} <-
           build_file(blocks, @early_groups, early_year, early_dates, start_row, end_row, events_row),
         {:ok, late} <-
           build_file(blocks, @late_groups, late_year, late_dates, start_row, end_row, events_row) do
      {:ok, %{early: early, late: late}}
    end
  end

  @doc """
  Returns the academic year a date belongs to, where a year starts in July.

      iex> ResidencySchedule.Importer.SummerFloatSplitter.academic_start_year(~D[2025-07-01])
      2025

      iex> ResidencySchedule.Importer.SummerFloatSplitter.academic_start_year(~D[2026-06-30])
      2025
  """
  def academic_start_year(%Date{year: year, month: month}) do
    if month >= 7, do: year, else: year - 1
  end

  # --- File assembly ---

  defp build_file(blocks, groups, year, dates, start_row, end_row, events_row) do
    column_indices = Enum.map(dates, &elem(&1, 0))
    separator = List.duplicate("", 2 + length(column_indices))

    groups
    |> Enum.map(fn {group_index, level} ->
      build_group(Enum.at(blocks, group_index), year, level, column_indices)
    end)
    |> collect()
    |> case do
      {:ok, group_rows} ->
        body = group_rows |> Enum.intersperse([separator]) |> Enum.concat()
        rows = header_rows(start_row, end_row, events_row, column_indices) ++ body
        {:ok, Csv.encode(rows)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp header_rows(start_row, end_row, events_row, column_indices) do
    [
      ["", "Resident"] ++ slice(start_row, column_indices),
      ["", ""] ++ slice(end_row, column_indices),
      ["Special Events", ""] ++ slice(events_row, column_indices)
    ]
  end

  defp build_group(block, year, level, column_indices) do
    1..8
    |> Enum.map(fn number ->
      code = "R#{level}-#{number}"
      canonical = NameNormalizer.normalize(year, code, "")

      case find_resident_row(block, canonical) do
        nil -> {:error, {:unmatched, code, canonical}}
        row -> {:ok, [code, canonical] ++ slice(row, column_indices)}
      end
    end)
    |> collect()
  end

  defp find_resident_row(block, canonical) do
    target = normalize_name(canonical)

    Enum.find(block, &(normalize_name(resident_name(&1)) == target)) ||
      Enum.find(block, &(aliased_name(resident_name(&1)) == target)) ||
      Enum.find(block, &(first_token(resident_name(&1)) == first_token(canonical)))
  end

  defp resident_name(row), do: List.first(row, "")

  defp aliased_name(name) do
    normalized = normalize_name(name)
    Map.get(@aliases, normalized, normalized)
  end

  defp first_token(name) do
    name
    |> normalize_name()
    |> String.split(" ")
    |> List.first("")
  end

  defp normalize_name(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/, " ")
  end

  # --- Column selection ---

  defp date_columns(start_row, cutoff, side) do
    start_row
    |> Enum.with_index()
    |> Enum.flat_map(fn {value, index} ->
      case Date.from_iso8601(value) do
        {:ok, date} -> [{index, date}]
        {:error, _} -> []
      end
    end)
    |> Enum.filter(fn {_index, date} -> in_side?(date, cutoff, side) end)
  end

  defp in_side?(date, cutoff, :early), do: Date.compare(date, cutoff) != :gt
  defp in_side?(date, cutoff, :late), do: Date.compare(date, cutoff) == :gt

  defp slice(row, column_indices) do
    Enum.map(column_indices, &Enum.at(row, &1, ""))
  end

  # --- Block grouping ---

  defp group_blocks(rows) do
    rows
    |> Enum.chunk_by(&blank_name?/1)
    |> Enum.reject(fn [first | _] -> blank_name?(first) end)
  end

  defp blank_name?(row), do: row |> resident_name() |> String.trim() == ""

  defp ensure_block_count(blocks) when length(blocks) == 5, do: :ok
  defp ensure_block_count(blocks), do: {:error, {:unexpected_block_count, length(blocks)}}

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
end
