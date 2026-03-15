defmodule ResidencySchedule.Importer.CsvParserTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Importer.CsvParser

  describe "parse_date_row/1" do
    test "parses valid ISO 8601 date strings, dropping first two cols" do
      row = ["", "Dates", "2026-07-06", "2026-07-13"]
      assert CsvParser.parse_date_row(row) == [~D[2026-07-06], ~D[2026-07-13]]
    end

    test "drops empty trailing cells" do
      row = ["", "Dates", "2026-07-06", "", ""]
      assert CsvParser.parse_date_row(row) == [~D[2026-07-06]]
    end

    test "drops nil cells" do
      row = ["", "Dates", "2026-07-06", nil]
      assert CsvParser.parse_date_row(row) == [~D[2026-07-06]]
    end

    test "returns empty list when no date columns" do
      assert CsvParser.parse_date_row(["", ""]) == []
    end
  end

  describe "fix_year_rollover/1" do
    test "leaves dates unchanged when all ascending" do
      dates = [~D[2026-07-06], ~D[2026-08-01], ~D[2026-09-15]]
      assert CsvParser.fix_year_rollover(dates) == dates
    end

    test "increments year after rollover point" do
      dates = [~D[2026-11-01], ~D[2026-12-01], ~D[2026-01-01], ~D[2026-02-01]]
      result = CsvParser.fix_year_rollover(dates)
      assert Enum.at(result, 2) == ~D[2027-01-01]
      assert Enum.at(result, 3) == ~D[2027-02-01]
    end

    test "does not modify dates before the rollover point" do
      dates = [~D[2023-07-03], ~D[2023-12-25], ~D[2023-01-01]]
      result = CsvParser.fix_year_rollover(dates)
      assert Enum.at(result, 0) == ~D[2023-07-03]
      assert Enum.at(result, 1) == ~D[2023-12-25]
      assert Enum.at(result, 2) == ~D[2024-01-01]
    end

    test "handles single-element list" do
      assert CsvParser.fix_year_rollover([~D[2026-07-06]]) == [~D[2026-07-06]]
    end

    test "handles empty list" do
      assert CsvParser.fix_year_rollover([]) == []
    end
  end

  describe "derive_academic_year/1" do
    test "returns year of the earliest date" do
      dates = [~D[2026-07-03], ~D[2026-08-01], ~D[2027-01-15]]
      assert CsvParser.derive_academic_year(dates) == 2026
    end

    test "works when earliest is not the first in list" do
      dates = [~D[2027-01-01], ~D[2026-07-06], ~D[2027-06-01]]
      assert CsvParser.derive_academic_year(dates) == 2026
    end
  end

  describe "parse/1" do
    test "parses the sample fixture with no hard failure" do
      csv = File.read!("test/fixtures/sample_schedule.csv")
      assert {:ok, residents, _warnings} = CsvParser.parse(csv)
      assert length(residents) > 0
    end

    test "all parsed residents have a non-empty name" do
      csv = File.read!("test/fixtures/sample_schedule.csv")
      {:ok, residents, _warnings} = CsvParser.parse(csv)
      assert Enum.all?(residents, fn r -> r.name != "" end)
    end

    test "all parsed residents have a valid position_code" do
      csv = File.read!("test/fixtures/sample_schedule.csv")
      {:ok, residents, _warnings} = CsvParser.parse(csv)
      pattern = ~r/^R[1-4]-\d+$/

      assert Enum.all?(residents, fn r ->
               Regex.match?(pattern, r.position_code)
             end)
    end

    test "R4-1 (Alexis) is present and has rotations" do
      csv = File.read!("test/fixtures/sample_schedule.csv")
      {:ok, residents, _warnings} = CsvParser.parse(csv)
      alexis = Enum.find(residents, &(&1.position_code == "R4-1"))
      assert alexis != nil
      assert alexis.name == "Alexis"
      assert length(alexis.rotations) > 0
    end

    test "residency_year and schedule_number are integers" do
      csv = File.read!("test/fixtures/sample_schedule.csv")
      {:ok, residents, _warnings} = CsvParser.parse(csv)

      Enum.each(residents, fn r ->
        assert is_integer(r.residency_year)
        assert r.residency_year in 1..4
        assert is_integer(r.schedule_number)
      end)
    end

    test "start dates are corrected for year rollover (no Jan date has year 2023)" do
      csv = File.read!("test/fixtures/sample_schedule.csv")
      {:ok, residents, _warnings} = CsvParser.parse(csv)

      all_dates =
        Enum.flat_map(residents, fn r ->
          Enum.flat_map(r.rotations, &[&1.start_date, &1.end_date])
        end)

      bad_dates = Enum.filter(all_dates, fn d -> d.month in 1..6 and d.year == 2023 end)
      assert bad_dates == [], "Found dates with wrong year: #{inspect(bad_dates)}"
    end

    test "backtick junk cell in R2-1 produces a warning, not a crash" do
      csv = File.read!("test/fixtures/sample_schedule.csv")
      {:ok, _residents, warnings} = CsvParser.parse(csv)
      backtick_warnings = Enum.filter(warnings, fn {_code, _idx, val} -> val == "`" end)
      assert length(backtick_warnings) > 0
    end

    test "returns ok with empty residents for a CSV with no resident rows" do
      assert {:ok, [], []} = CsvParser.parse("not,valid\nCSV\nwithout dates")
    end

    test "empty cells are not stored as rotations" do
      csv = File.read!("test/fixtures/sample_schedule.csv")
      {:ok, residents, _warnings} = CsvParser.parse(csv)

      Enum.each(residents, fn r ->
        Enum.each(r.rotations, fn rot ->
          assert rot.rotation_type != nil
        end)
      end)
    end
  end

  describe "parse/1 — separator column alignment (2025-2026 fixture)" do
    test "Clare (R3-1) has strong_weekend_nights for 2026-03-07 to 2026-03-08" do
      csv = File.read!("test/fixtures/2025-2026.csv")
      {:ok, residents, _warnings} = CsvParser.parse(csv)
      clare = Enum.find(residents, &(&1.position_code == "R3-1"))
      assert clare != nil

      swn =
        Enum.find(clare.rotations, fn r ->
          r.start_date == ~D[2026-03-07] and r.end_date == ~D[2026-03-08]
        end)

      assert swn != nil, "Expected SWN rotation for 2026-03-07..03-08, got: #{inspect(Enum.filter(clare.rotations, &(&1.start_date.month == 3)))}"
      assert swn.rotation_type == :strong_weekend_nights
    end

    test "Clare (R3-1) has night_float for 2026-03-09 to 2026-03-13" do
      csv = File.read!("test/fixtures/2025-2026.csv")
      {:ok, residents, _warnings} = CsvParser.parse(csv)
      clare = Enum.find(residents, &(&1.position_code == "R3-1"))

      nf =
        Enum.find(clare.rotations, fn r ->
          r.start_date == ~D[2026-03-09] and r.end_date == ~D[2026-03-13]
        end)

      assert nf != nil, "Expected NF rotation for 2026-03-09..03-13"
      assert nf.rotation_type == :night_float
    end

    test "Clare (R3-1) has post_call for 2026-03-14 to 2026-03-15" do
      csv = File.read!("test/fixtures/2025-2026.csv")
      {:ok, residents, _warnings} = CsvParser.parse(csv)
      clare = Enum.find(residents, &(&1.position_code == "R3-1"))

      pc =
        Enum.find(clare.rotations, fn r ->
          r.start_date == ~D[2026-03-14] and r.end_date == ~D[2026-03-15]
        end)

      assert pc != nil, "Expected post_call rotation for 2026-03-14..03-15"
      assert pc.rotation_type == :post_call
    end
  end
end
