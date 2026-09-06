defmodule ResidencySchedule.Assistant.LocalDateTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Assistant.LocalDate

  doctest LocalDate

  describe "today/0" do
    test "is within a day of UTC today" do
      assert abs(Date.diff(LocalDate.today(), Date.utc_today())) <= 1
    end
  end

  describe "parse/1" do
    test "nil and empty mean today" do
      assert {:ok, today} = LocalDate.parse(nil)
      assert today == LocalDate.today()
      assert {:ok, ^today} = LocalDate.parse("")
    end

    test "trims whitespace" do
      assert {:ok, ~D[2026-09-06]} = LocalDate.parse(" 2026-09-06 ")
    end

    test "rejects non-strings" do
      assert {:error, :invalid_date} = LocalDate.parse(42)
    end
  end

  describe "parse_optional/1" do
    test "empty string is nil and bad text errors" do
      assert {:ok, nil} = LocalDate.parse_optional("")
      assert {:error, :invalid_date} = LocalDate.parse_optional("soon")
    end
  end
end
