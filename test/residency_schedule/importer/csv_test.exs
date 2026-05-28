defmodule ResidencySchedule.Importer.CsvTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Importer.Csv

  doctest Csv

  describe "parse/1" do
    test "splits plain rows" do
      assert Csv.parse("a,b,c\n") == [["a", "b", "c"]]
    end

    test "keeps a comma inside a quoted field" do
      assert Csv.parse("x,\"OR HOLIDAY, NO TB\",y\n") == [["x", "OR HOLIDAY, NO TB", "y"]]
    end

    test "tolerates CRLF line endings" do
      assert Csv.parse("a,b\r\nc,d\r\n") == [["a", "b"], ["c", "d"]]
    end

    test "drops blank lines" do
      assert Csv.parse("a,b\n\n\nc,d\n") == [["a", "b"], ["c", "d"]]
    end
  end

  describe "encode/1" do
    test "quotes fields containing a comma" do
      assert Csv.encode([["x", "OR HOLIDAY, NO TB"]]) == "x,\"OR HOLIDAY, NO TB\"\n"
    end

    test "leaves plain fields unquoted" do
      assert Csv.encode([["a", "b"], ["c", "d"]]) == "a,b\nc,d\n"
    end

    test "round-trips a quoted field" do
      rows = [["a", "b,c", "d"]]
      assert rows |> Csv.encode() |> Csv.parse() == rows
    end
  end
end
