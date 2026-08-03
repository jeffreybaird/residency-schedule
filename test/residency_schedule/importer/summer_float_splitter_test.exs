defmodule ResidencySchedule.Importer.SummerFloatSplitterTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Importer.CsvParser
  alias ResidencySchedule.Importer.SummerFloatSplitter

  doctest SummerFloatSplitter

  @fixture File.read!("test/fixtures/summer_float.csv")

  defp split, do: SummerFloatSplitter.split(@fixture)

  defp lines(csv), do: csv |> String.split("\n", trim: true)

  defp resident_rows(csv) do
    csv
    |> lines()
    |> Enum.map(&String.split(&1, ","))
    |> Enum.filter(fn [code | _] -> Regex.match?(~r/^R[1-4]-\d+$/, code) end)
  end

  defp code_to_name(csv) do
    csv
    |> resident_rows()
    |> Map.new(fn [code, name | _] -> {code, name} end)
  end

  describe "split/2" do
    test "returns early and late binaries" do
      assert {:ok, %{early: early, late: late}} = split()
      assert is_binary(early)
      assert is_binary(late)
    end

    test "each file has exactly 32 residents (four classes of eight)" do
      {:ok, %{early: early, late: late}} = split()
      assert length(resident_rows(early)) == 32
      assert length(resident_rows(late)) == 32
    end

    test "both files carry every position code R4-1..R1-8" do
      {:ok, %{early: early, late: late}} = split()
      expected = for level <- 1..4, number <- 1..8, do: "R#{level}-#{number}"

      assert Enum.sort(Map.keys(code_to_name(early))) == Enum.sort(expected)
      assert Enum.sort(Map.keys(code_to_name(late))) == Enum.sort(expected)
    end
  end

  describe "split/2 seniority shift" do
    test "graduating R4s are the early R4s and are absent from the late file" do
      {:ok, %{early: early, late: late}} = split()
      assert code_to_name(early)["R4-1"] == "Fern"

      late_names = late |> code_to_name() |> Map.values()
      refute "Fern" in late_names
    end

    test "rising R4s are R3 in the early file and R4 in the late file" do
      {:ok, %{early: early, late: late}} = split()
      assert code_to_name(early)["R3-1"] == "Isolde"
      assert code_to_name(late)["R4-6"] == "Isolde"
    end

    test "interns are the late R1s and are absent from the early file" do
      {:ok, %{early: early, late: late}} = split()
      assert code_to_name(late)["R1-1"] == "Astrid"

      early_names = early |> code_to_name() |> Map.values()
      refute "Astrid" in early_names
    end
  end

  describe "split/2 name reconciliation" do
    test "alias names resolve to canonical form (Aleksandra -> Sasha)" do
      {:ok, %{early: early, late: late}} = split()
      assert code_to_name(early)["R1-4"] == "Sasha"
      assert code_to_name(late)["R2-7"] == "Sasha"
    end

    test "first-token names resolve to suffixed canonical form (Rose -> Rosie)" do
      {:ok, %{early: early}} = split()
      assert code_to_name(early)["R4-5"] == "Rosie"
    end

    test "rising-class rows are reordered to canonical position order in the late file" do
      {:ok, %{late: late}} = split()
      names = late |> code_to_name()
      assert names["R4-1"] == "Juno R"
      assert names["R4-2"] == "Solene"
      assert names["R4-8"] == "Opal"
    end
  end

  describe "split/2 date columns" do
    defp date_header(csv), do: csv |> lines() |> hd() |> String.split(",")

    test "early file ends on the cutoff date and late file starts the day after" do
      {:ok, %{early: early, late: late}} = split()
      assert List.last(date_header(early)) == "2026-06-17"
      # header is ["", "Resident", first_date, ...]
      assert Enum.at(date_header(late), 2) == "2026-06-18"
    end

    test "drops the trailing Days off / Post call summary columns" do
      {:ok, %{early: early}} = split()
      refute String.contains?(early, "Days off")
      refute String.contains?(early, "Post call")
    end
  end

  describe "split/2 events row" do
    test "preserves a quoted event cell containing a comma in the late file" do
      {:ok, %{late: late}} = split()
      assert String.contains?(late, "\"OR HOLIDAY, NO TB\"")
    end
  end

  describe "split/2 round-trips through the importer" do
    test "early output parses into 32 residents" do
      {:ok, %{early: early}} = split()
      assert {:ok, residents, _warnings} = CsvParser.parse(early)
      assert length(residents) == 32
    end

    test "late output parses into 32 residents" do
      {:ok, %{late: late}} = split()
      assert {:ok, residents, _warnings} = CsvParser.parse(late)
      assert length(residents) == 32
    end
  end

  describe "split/2 error paths" do
    test "returns an error when a roster row is missing" do
      broken = String.replace(@fixture, ~r/^Isolde,.*\n/m, "")
      assert {:error, {:unmatched, "R3-1", "Isolde"}} = SummerFloatSplitter.split(broken)
    end

    test "returns an error when the block structure is unexpected" do
      one_block =
        @fixture
        |> String.split("\n")
        |> Enum.take(5)
        |> Enum.join("\n")

      assert {:error, {:unexpected_block_count, _}} = SummerFloatSplitter.split(one_block)
    end
  end
end
