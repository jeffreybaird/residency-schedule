defmodule ResidencySchedule.Importer.ScheduleMergerTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Importer.CsvParser
  alias ResidencySchedule.Importer.ScheduleMerger
  alias ResidencySchedule.Importer.SummerFloatSplitter

  doctest ScheduleMerger

  @base File.read!("test/fixtures/2025-2026.csv")
  @base_2027 File.read!("test/fixtures/2026-2027.csv")

  setup_all do
    {:ok, %{early: early, late: late}} =
      "test/fixtures/summer_float_sample.csv" |> File.read!() |> SummerFloatSplitter.split()

    %{early: early, late: late}
  end

  defp resident_line(csv, code) do
    csv
    |> String.split("\n", trim: true)
    |> Enum.find(&String.starts_with?(&1, code <> ","))
    |> String.split(",")
  end

  describe "merge/2" do
    test "returns merged csv and conflicts", %{early: early} do
      assert {:ok, %{csv: csv, conflicts: conflicts}} = ScheduleMerger.merge(@base, early)
      assert is_binary(csv)
      assert is_list(conflicts)
    end

    test "appends the early period so the timeline ends on 2026-06-17", %{early: early} do
      {:ok, %{csv: csv}} = ScheduleMerger.merge(@base, early)
      start_row = csv |> String.split("\n") |> hd() |> String.split(",")
      assert List.last(start_row) == "2026-06-17"
    end

    test "the summer-float value wins for each resident's appended columns", %{early: early} do
      {:ok, %{csv: csv}} = ScheduleMerger.merge(@base, early)
      # R4-3 Carolyn in early: AMB,OFF,OFF,NF,NF,P (06-08..06-17)
      assert Enum.take(resident_line(csv, "R4-3"), -6) == ["AMB", "OFF", "OFF", "NF", "NF", "P"]
    end

    test "leaves the mid-year winter float untouched", %{early: early} do
      {:ok, %{csv: csv}} = ScheduleMerger.merge(@base, early)
      # Winter float (Dec 22 -> Jan 4) is well before the cutoff and survives.
      assert String.contains?(csv, "FLOAT")
    end
  end

  describe "merge/2 conflict detection" do
    test "reports exactly the real overlapping disagreements", %{early: early} do
      {:ok, %{conflicts: conflicts}} = ScheduleMerger.merge(@base, early)
      assert length(conflicts) == 12
    end

    test "captures a weekend-vs-float disagreement", %{early: early} do
      {:ok, %{conflicts: conflicts}} = ScheduleMerger.merge(@base, early)

      assert %{position_code: "R4-3", date: ~D[2026-06-13], base: "SWN", addon: "OFF"} =
               Enum.find(conflicts, &(&1.position_code == "R4-3" and &1.date == ~D[2026-06-13]))
    end

    test "ignores whitespace-only differences", %{early: early} do
      {:ok, %{conflicts: conflicts}} = ScheduleMerger.merge(@base, early)
      # R2-5 base 06-13 is "HWN"; early is "HWN " -> trimmed equal, not a conflict.
      r2_5_dates = conflicts |> Enum.filter(&(&1.position_code == "R2-5")) |> Enum.map(& &1.date)
      refute ~D[2026-06-13] in r2_5_dates
      assert ~D[2026-06-14] in r2_5_dates
    end
  end

  describe "merge/2 round-trips through the importer" do
    test "merged output parses into 32 residents", %{early: early} do
      {:ok, %{csv: csv}} = ScheduleMerger.merge(@base, early)
      assert {:ok, residents, _warnings} = CsvParser.parse(csv)
      assert length(residents) == 32
    end
  end

  describe "merge/2 error paths" do
    test "errors when the add-on is missing a resident the base requires", %{early: early} do
      broken = String.replace(early, ~r/^R4-3,.*\n/m, "")
      assert {:error, {:missing_addon_row, "R4-3"}} = ScheduleMerger.merge(@base, broken)
    end
  end

  describe "prepend/2" do
    test "returns merged csv and conflicts", %{late: late} do
      assert {:ok, %{csv: csv, conflicts: conflicts}} = ScheduleMerger.prepend(@base_2027, late)
      assert is_binary(csv)
      assert is_list(conflicts)
    end

    test "inserts the late runway so the timeline now starts on 2026-06-18", %{late: late} do
      {:ok, %{csv: csv}} = ScheduleMerger.prepend(@base_2027, late)
      start_row = csv |> String.split("\n") |> hd() |> String.split(",")
      # ["", "Resident", first_date, ...]
      assert Enum.at(start_row, 2) == "2026-06-18"
    end

    test "keeps the base's columns from its own first date onward", %{late: late} do
      {:ok, %{csv: csv}} = ScheduleMerger.prepend(@base_2027, late)
      start_row = csv |> String.split("\n") |> hd() |> String.split(",")
      # base 2026-2027 ran through 2027-06-21; still the last column after prepend.
      assert List.last(start_row) == "2027-06-21"
    end

    test "the base 2026-2027 value wins on the overlap", %{late: late} do
      {:ok, %{csv: csv}} = ScheduleMerger.prepend(@base_2027, late)
      # R4-1 Paige R: late ends ...HGYN,HWN (06-29) then FLOAT,FLOAT (07-04);
      # base 2026-2027 R4-1 begins HGYN,HWN (06-29). The 06-29 cell must be the
      # base value, not the late FLOAT.
      paige = resident_line(csv, "R4-1")
      refute "FLOAT" in Enum.slice(paige, 0..14)
    end

    test "no real conflicts (06-29 matches; 07-04 base blanks are not conflicts)", %{late: late} do
      {:ok, %{conflicts: conflicts}} = ScheduleMerger.prepend(@base_2027, late)
      assert conflicts == []
    end

    test "merged output parses into 32 residents", %{late: late} do
      {:ok, %{csv: csv}} = ScheduleMerger.prepend(@base_2027, late)
      assert {:ok, residents, _warnings} = CsvParser.parse(csv)
      assert length(residents) == 32
    end

    test "errors when the add-on is missing a resident the base requires", %{late: late} do
      broken = String.replace(late, ~r/^R4-1,.*\n/m, "")
      assert {:error, {:missing_addon_row, "R4-1"}} = ScheduleMerger.prepend(@base_2027, broken)
    end
  end
end
