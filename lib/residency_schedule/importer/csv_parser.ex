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

  defstruct [
    :position_code,
    :residency_year,
    :schedule_number,
    :name,
    :rotations,
    date_updates: []
  ]

  @resident_row_pattern ~r/^R([1-4])-(\d+)$/

  @rotation_abbreviations %{
    "loa" => :leave_of_absence,
    "admin" => :admin,
    "admin/mfm" => :admin_mfm,
    "cob" => :cob,
    "gog/colpo" => :gog_colpo,
    "mfm" => :mfm,
    "mfm/pain" => :mfm_pain,
    "mfm pm" => :mfm_pm,
    "orient" => :orientation,
    "onc (orient)" => :oncology_orientation,
    "hhob (orient)" => :highland_obstetrics_orientation,
    "gyn (orient)" => :strong_gynecology_orientation,
    "hgyn (orient)" => :highland_gynecology_orientation,
    "ob (orient)" => :strong_obstetrics_orientation,
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
    "us" => :ultrasound,
    # "usn" is the legacy abbreviation for ultrasound, replaced by "us" in 2025-2026
    "usn" => :ultrasound,
    "vac" => :vacation
  }

  @doc """
  Parses a CSV binary into a list of resident structs plus warnings.

  Returns `{:ok, residents, warnings}` where:
  - `residents` is a list of `%CsvParser{}` structs
  - `warnings` is a list of `{position_code, slot_index, unknown_value}` tuples

  Returns `{:error, reason}` if the file cannot be parsed at all.

      iex> csv = File.read!("test/fixtures/sample.csv")
      iex> {:ok, residents, _warnings} = ResidencySchedule.Importer.CsvParser.parse(csv)
      iex> length(residents) > 0
      true
  """
  def parse(csv_binary) do
    rows = decode_rows(csv_binary)

    with {:ok, slots, academic_year} <- extract_slots(rows) do
      extract_residents(rows, slots, academic_year)
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  @doc """
  Parses a date update using literal source dates and the selected roster year.
  Blank and unknown cells preserve existing assignments; OFF explicitly clears.
  Highland weekend nights retain their Saturday-only shift boundary.

      iex> csv = Enum.join([",Dates,2026-12-14", ",,2026-12-14", ",,", "R1-1,Resident,HNF"], <<10>>)
      iex> {:ok, [resident], []} = ResidencySchedule.Importer.CsvParser.parse_date_update(csv, 2026)
      iex> hd(resident.rotations).start_date
      ~D[2026-12-14]
  """
  def parse_date_update(csv_binary, academic_year) do
    rows = decode_rows(csv_binary)

    with {:ok, slots} <- update_slots(rows, academic_year),
         :ok <- unique_update_residents(rows) do
      rows
      |> Enum.filter(&resident_row?/1)
      |> Enum.reduce({[], []}, fn row, {residents, warnings} ->
        {resident, new_warnings} = build_date_update(row, slots, academic_year)
        {[resident | residents], warnings ++ new_warnings}
      end)
      |> then(fn {residents, warnings} -> {:ok, Enum.reverse(residents), warnings} end)
    end
  rescue
    e -> {:error, Exception.message(e)}
  end

  defp update_slots(rows, year) when is_integer(year) and year in 1..9998 do
    starts = Map.new(parse_indexed_date_columns(Enum.at(rows, 0, [])))
    ends = Map.new(parse_indexed_date_columns(Enum.at(rows, 1, [])))

    slots =
      starts
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.with_index()
      |> Enum.map(fn {{column, start}, index} ->
        {column, {index, start, Map.get(ends, column)}}
      end)

    first = Date.new!(year, 7, 1)
    last = Date.new!(year + 1, 6, 30)
    ranges = Enum.map(slots, fn {_, {_, start, finish}} -> {start, finish} end)

    cond do
      slots == [] or Enum.sort(Map.keys(starts)) != Enum.sort(Map.keys(ends)) ->
        {:error, "Each update column needs matching start and end dates"}

      Enum.any?(ranges, fn {start, finish} ->
        Date.compare(start, finish) == :gt or Date.compare(start, first) == :lt or
            Date.compare(finish, last) == :gt
      end) ->
        {:error, "Update dates must be ordered and inside the selected July–June academic year"}

      overlapping_update_slots?(ranges) ->
        {:error, "Update date columns must not overlap"}

      true ->
        {:ok, Map.new(slots)}
    end
  end

  defp update_slots(_rows, _year),
    do: {:error, "Select an existing academic year for date updates"}

  defp overlapping_update_slots?(ranges) do
    ranges
    |> Enum.sort_by(fn {start, _} -> Date.to_gregorian_days(start) end)
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [{_, finish}, {start, _}] -> Date.compare(start, finish) != :gt end)
  end

  defp unique_update_residents(rows) do
    codes = rows |> Enum.filter(&resident_row?/1) |> Enum.map(&hd/1)

    if length(codes) == length(Enum.uniq(codes)),
      do: :ok,
      else: {:error, "Duplicate resident positions in update"}
  end

  defp build_date_update(row, slots, year) do
    {resident, _} = build_resident(row, %{}, year)

    {updates, warnings} =
      row
      |> Enum.drop(2)
      |> Enum.with_index()
      |> Enum.reduce({[], []}, fn {cell, column}, {updates, warnings} ->
        collect_date_update(
          String.trim(cell),
          Map.get(slots, column),
          resident.position_code,
          updates,
          warnings
        )
      end)

    updates = Enum.reverse(updates)
    rotations = updates |> Enum.map(& &1.rotation) |> Enum.reject(&is_nil/1)
    {%{resident | rotations: rotations, date_updates: updates}, warnings}
  end

  defp collect_date_update("", _slot, _code, updates, warnings), do: {updates, warnings}
  defp collect_date_update(_value, nil, _code, updates, warnings), do: {updates, warnings}

  defp collect_date_update(value, {index, start, finish}, code, updates, warnings) do
    case {Map.get(@rotation_abbreviations, normalize_rotation_key(value)), String.upcase(value)} do
      {nil, label} when label != "OFF" ->
        {updates, warnings ++ [{code, index, value}]}

      {type, _} ->
        rotation = date_update_rotation(type, index, start, finish)
        update = %{start_date: start, end_date: finish, rotation: rotation}
        {[update | updates], warnings}
    end
  end

  defp date_update_rotation(nil, _index, _start, _finish), do: nil

  defp date_update_rotation(type, index, start, finish) do
    finish = if type == :highland_weekend_nights, do: start, else: finish
    %{slot_index: index, start_date: start, end_date: finish, rotation_type: type}
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

    name =
      NameNormalizer.normalize(academic_year, position_code, name_raw)
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
          key = normalize_rotation_key(trimmed)

          collect_rotation(
            key,
            trimmed,
            position_code,
            slot_index,
            start_date,
            end_date,
            rotations,
            warnings
          )
      end
    end)
    |> then(fn {rotations, warnings} ->
      {Enum.reverse(rotations), Enum.reverse(warnings)}
    end)
  end

  @doc """
  Adjusts date ranges for Highland rotations whose actual shift times differ
  from the standard slot boundaries.

  Highland Night Float runs Sunday night through Friday night, so its start
  date shifts back one day (from Monday to Sunday). Highland Weekend Nights
  is a single Saturday night shift, so its end date is set equal to its
  start date.

      iex> ResidencySchedule.Importer.CsvParser.adjust_highland_dates(:highland_night_float, ~D[2025-07-07], ~D[2025-07-11])
      {~D[2025-07-06], ~D[2025-07-11]}

      iex> ResidencySchedule.Importer.CsvParser.adjust_highland_dates(:highland_weekend_nights, ~D[2025-07-05], ~D[2025-07-06])
      {~D[2025-07-05], ~D[2025-07-05]}

      iex> ResidencySchedule.Importer.CsvParser.adjust_highland_dates(:strong_obstetrics, ~D[2025-07-07], ~D[2025-07-11])
      {~D[2025-07-07], ~D[2025-07-11]}
  """
  def adjust_highland_dates(:highland_night_float, start_date, end_date) do
    {Date.add(start_date, -1), end_date}
  end

  def adjust_highland_dates(:highland_weekend_nights, start_date, _end_date) do
    {start_date, start_date}
  end

  def adjust_highland_dates(_rotation_type, start_date, end_date) do
    {start_date, end_date}
  end

  defp reject_empty_cells(cells) do
    Enum.reject(cells, &(&1 == "" or is_nil(&1)))
  end

  defp normalize_rotation_key(value) do
    value
    |> String.trim()
    |> String.replace(~r/\s+-\s+till 8p$/i, "")
    |> String.downcase()
  end

  defp collect_rotation(
         key,
         trimmed,
         position_code,
         slot_index,
         start_date,
         end_date,
         rotations,
         warnings
       ) do
    case Map.get(@rotation_abbreviations, key) do
      nil ->
        warning = {position_code, slot_index, trimmed}
        {rotations, [warning | warnings]}

      rotation_type ->
        {adj_start, adj_end} =
          adjust_highland_dates(rotation_type, start_date, end_date)

        rotation = %{
          slot_index: slot_index,
          start_date: adj_start,
          end_date: adj_end,
          rotation_type: rotation_type
        }

        {[rotation | rotations], warnings}
    end
  end
end
