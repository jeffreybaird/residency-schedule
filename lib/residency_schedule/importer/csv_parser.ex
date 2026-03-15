defmodule ResidencySchedule.Importer.CsvParser do
  @moduledoc """
  Parses the OB/GYN residency schedule CSV format into structured data.

  CSV structure:
    Row 0: start dates (col A = "", col B = "Dates", cols C+ = date strings)
    Row 1: end dates   (col A = "", col B = "",      cols C+ = date strings)
    Row 2: event annotations (skip)
    Rows 3+: resident rows (col A matches R<year>-<number>) or separator/legend rows (skip)

  Names are normalized to canonical form via `NameNormalizer` so the same
  resident's name is consistent across all schedule years.
  """

  alias ResidencySchedule.Importer.NameNormalizer

  defstruct [:position_code, :residency_year, :schedule_number, :name, :rotations]

  @resident_row_pattern ~r/^R([1-4])-(\d+)$/

  @rotation_abbreviations %{
    "amb" => :ambulatory,
    "away" => :away_rotation,
    "elective" => :elective,
    "float" => :float,
    "gyn" => :strong_gynecology,
    "hgyn" => :highland_gynecology,
    "hhob" => :highland_obstetrics,
    "hnf" => :highland_night_float,
    "hwd" => :highland_weekend_days,
    "hwn" => :highland_weekend_nights,
    "nf" => :night_float,
    "ob" => :strong_obstetrics,
    "onc" => :oncology,
    "p" => :post_call,
    "rei" => :rei,
    "swd" => :strong_weekend_days,
    "swn" => :strong_weekend_nights,
    "swing" => :swing,
    "ug" => :urogynecology,
    "usn" => :unknown,
    "vac" => :vacation
  }

  @doc """
  Parses a CSV binary into a list of resident structs plus warnings.

  Returns `{:ok, residents, warnings}` where:
  - `residents` is a list of `%CsvParser{}` structs
  - `warnings` is a list of `{position_code, slot_index, unknown_value}` tuples

  Returns `{:error, reason}` if the file cannot be parsed at all.

      iex> csv = File.read!("test/fixtures/sample_schedule.csv")
      iex> {:ok, residents, _warnings} = ResidencySchedule.Importer.CsvParser.parse(csv)
      iex> length(residents) > 0
      true
  """
  def parse(csv_binary) do
    rows = decode_rows(csv_binary)

    with {:ok, slots, academic_year} <- extract_slots(rows),
         {:ok, residents, warnings} <- extract_residents(rows, slots, academic_year) do
      {:ok, residents, warnings}
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Derives the academic year (start year) from a list of dates.
  The earliest date's year is the academic year start.

      iex> dates = [~D[2026-07-03], ~D[2026-08-01], ~D[2027-01-15]]
      iex> ResidencySchedule.Importer.CsvParser.derive_academic_year(dates)
      2026
  """
  def derive_academic_year(dates) do
    dates
    |> Enum.min(Date)
    |> Map.fetch!(:year)
  end

  @doc """
  Corrects year rollover: when dates are listed as 2023-01-xx but should be 2024-01-xx
  (the second half of an academic year that started in July 2023).

  Walks the date list; whenever a date is earlier than the previous, increments the year
  on that date and all following dates.

      iex> dates = [~D[2023-11-01], ~D[2023-12-01], ~D[2023-01-01], ~D[2023-02-01]]
      iex> fixed = ResidencySchedule.Importer.CsvParser.fix_year_rollover(dates)
      iex> Enum.at(fixed, 2)
      ~D[2024-01-01]

      iex> dates = [~D[2026-07-06], ~D[2026-08-01], ~D[2026-09-15]]
      iex> ResidencySchedule.Importer.CsvParser.fix_year_rollover(dates)
      [~D[2026-07-06], ~D[2026-08-01], ~D[2026-09-15]]
  """
  def fix_year_rollover(dates) do
    dates
    |> Enum.reduce({nil, []}, fn date, {prev, acc} ->
      fixed =
        if prev && Date.compare(date, prev) == :lt do
          %{date | year: date.year + 1}
        else
          date
        end

      {fixed, [fixed | acc]}
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  @doc """
  Parses a raw date row (row 0 or row 1) by dropping the first two columns,
  filtering empty/nil cells, and parsing each remaining cell as an ISO 8601 date.

      iex> row = ["", "Dates", "2026-07-06", "2026-07-13", "", nil]
      iex> ResidencySchedule.Importer.CsvParser.parse_date_row(row)
      [~D[2026-07-06], ~D[2026-07-13]]
  """
  def parse_date_row(row) do
    row
    |> Enum.drop(2)
    |> reject_empty_cells()
    |> Enum.map(&Date.from_iso8601!/1)
  end

  # --- Private helpers ---

  defp decode_rows(csv_binary) do
    csv_binary
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing(&1, "\r"))
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&split_csv_row/1)
  end

  defp split_csv_row(line) do
    String.split(line, ",")
  end

  defp extract_slots(rows) do
    start_row = Enum.at(rows, 0, [])
    end_row = Enum.at(rows, 1, [])

    start_indexed = parse_indexed_date_columns(start_row)
    end_indexed = parse_indexed_date_columns(end_row)

    start_map = Map.new(start_indexed)
    end_map = Map.new(end_indexed)

    col_indices =
      start_indexed
      |> Enum.map(fn {idx, _} -> idx end)
      |> Enum.filter(&Map.has_key?(end_map, &1))

    start_dates = col_indices |> Enum.map(&start_map[&1]) |> fix_year_rollover()
    end_dates = col_indices |> Enum.map(&end_map[&1]) |> fix_year_rollover()

    slots_by_col =
      col_indices
      |> Enum.zip(start_dates)
      |> Enum.zip(end_dates)
      |> Enum.with_index()
      |> Enum.map(fn {{{col_idx, start_date}, end_date}, slot_idx} ->
        {col_idx, {slot_idx, start_date, end_date}}
      end)
      |> Map.new()

    academic_year = if start_dates == [], do: 0, else: derive_academic_year(start_dates)

    {:ok, slots_by_col, academic_year}
  end

  defp parse_indexed_date_columns(row) do
    row
    |> Enum.drop(2)
    |> Enum.with_index()
    |> Enum.reject(fn {val, _} -> val == "" or is_nil(val) end)
    |> Enum.map(fn {val, idx} -> {idx, Date.from_iso8601!(val)} end)
  end

  defp extract_residents(rows, slots, academic_year) do
    rows
    |> Enum.filter(&resident_row?/1)
    |> Enum.reduce({[], []}, fn row, {residents, warnings} ->
      {resident, new_warnings} = build_resident(row, slots, academic_year)
      {[resident | residents], warnings ++ new_warnings}
    end)
    |> then(fn {residents, warnings} ->
      {:ok, Enum.reverse(residents), warnings}
    end)
  end

  defp resident_row?(row) do
    col_a = List.first(row, "")
    Regex.match?(@resident_row_pattern, col_a)
  end

  defp build_resident(row, slots, academic_year) do
    [position_code | rest] = row
    [name_raw | cells] = rest

    [_, year_str, num_str] = Regex.run(@resident_row_pattern, position_code)
    residency_year = String.to_integer(year_str)
    schedule_number = String.to_integer(num_str)
    name = NameNormalizer.normalize(academic_year, position_code, name_raw)
      |> then(fn n -> if n == "", do: position_code, else: n end)

    {rotations, warnings} = build_rotations(position_code, cells, slots)

    resident = %__MODULE__{
      position_code: position_code,
      residency_year: residency_year,
      schedule_number: schedule_number,
      name: name,
      rotations: rotations
    }

    {resident, warnings}
  end

  defp build_rotations(position_code, cells, slots_by_col) do
    cells
    |> Enum.with_index()
    |> Enum.reduce({[], []}, fn {cell, col_idx}, {rotations, warnings} ->
      trimmed = String.trim(cell || "")

      cond do
        trimmed == "" ->
          {rotations, warnings}

        not Map.has_key?(slots_by_col, col_idx) ->
          {rotations, warnings}

        true ->
          {slot_index, start_date, end_date} = slots_by_col[col_idx]
          key = String.downcase(trimmed)

          case Map.get(@rotation_abbreviations, key) do
            nil ->
              warning = {position_code, slot_index, trimmed}
              {rotations, [warning | warnings]}

            rotation_type ->
              rotation = %{
                slot_index: slot_index,
                start_date: start_date,
                end_date: end_date,
                rotation_type: rotation_type
              }

              {[rotation | rotations], warnings}
          end
      end
    end)
    |> then(fn {rotations, warnings} ->
      {Enum.reverse(rotations), Enum.reverse(warnings)}
    end)
  end

  defp reject_empty_cells(cells) do
    Enum.reject(cells, &(&1 == "" or is_nil(&1)))
  end
end
