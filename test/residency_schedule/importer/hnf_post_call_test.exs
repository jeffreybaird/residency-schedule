defmodule ResidencySchedule.Importer.HnfPostCallTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Importer.CsvParser

  test "annual HNF Sunday start removes only the preceding Post Call Sunday" do
    csv = csv("P,HNF", "2026-11-07,2026-11-09", "2026-11-08,2026-11-13")
    assert {:ok, [resident], []} = CsvParser.parse(csv)

    assert spans(resident) == [
             {:post_call, ~D[2026-11-07], ~D[2026-11-07], 0},
             {:highland_night_float, ~D[2026-11-08], ~D[2026-11-13], 1}
           ]
  end

  test "annual parsing drops Post Call fully occupied by the shifted HNF start" do
    csv = csv("P,HNF", "2026-11-08,2026-11-09", "2026-11-08,2026-11-13")
    assert {:ok, [resident], []} = CsvParser.parse(csv)

    assert spans(resident) == [
             {:highland_night_float, ~D[2026-11-08], ~D[2026-11-13], 1}
           ]
  end

  test "annual parsing preserves a working assignment overlapping HNF Sunday" do
    csv = csv("OB,HNF", "2026-11-07,2026-11-09", "2026-11-08,2026-11-13")
    assert {:ok, [resident], []} = CsvParser.parse(csv)

    assert spans(resident) == [
             {:strong_obstetrics, ~D[2026-11-07], ~D[2026-11-08], 0},
             {:highland_night_float, ~D[2026-11-08], ~D[2026-11-13], 1}
           ]
  end

  test "Post Call preceding Strong night float retains the full weekend" do
    csv = csv("P,NF", "2026-11-07,2026-11-09", "2026-11-08,2026-11-13")
    assert {:ok, [resident], []} = CsvParser.parse(csv)

    assert spans(resident) == [
             {:post_call, ~D[2026-11-07], ~D[2026-11-08], 0},
             {:night_float, ~D[2026-11-09], ~D[2026-11-13], 1}
           ]
  end

  test "literal date updates do not shift HNF or shorten a nonoverlapping Post Call" do
    csv = csv("P,HNF", "2026-11-07,2026-11-09", "2026-11-08,2026-11-13")
    assert {:ok, [resident], []} = CsvParser.parse_date_update(csv, 2026)

    assert spans(resident) == [
             {:post_call, ~D[2026-11-07], ~D[2026-11-08], 0},
             {:highland_night_float, ~D[2026-11-09], ~D[2026-11-13], 1}
           ]
  end

  test "literal date updates still reject overlapping source date columns" do
    csv = csv("P,HNF", "2026-11-07,2026-11-08", "2026-11-08,2026-11-13")

    assert {:error, "Update date columns must not overlap"} =
             CsvParser.parse_date_update(csv, 2026)
  end

  defp csv(assignments, starts, ends) do
    Enum.join(
      [",Dates," <> starts, ",," <> ends, ",,Events", "R1-1,Example," <> assignments],
      "\n"
    )
  end

  defp spans(resident) do
    Enum.map(resident.rotations, &{&1.rotation_type, &1.start_date, &1.end_date, &1.slot_index})
  end
end
