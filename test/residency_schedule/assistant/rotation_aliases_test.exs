defmodule ResidencySchedule.Assistant.RotationAliasesTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Assistant.RotationAliases

  doctest RotationAliases

  describe "resolve/1" do
    test "matches shorthand regardless of case and punctuation" do
      assert {:ok, "oncology"} = RotationAliases.resolve("ONC")
      assert {:ok, "night_float"} = RotationAliases.resolve("NF")
      assert {:ok, "highland_obstetrics"} = RotationAliases.resolve("Highland OB")
      assert {:ok, "strong_weekend_nights"} = RotationAliases.resolve("swn")
    end

    test "accepts the stored type string with underscores" do
      assert {:ok, "strong_weekend_days"} = RotationAliases.resolve("strong_weekend_days")
    end

    test "rejects non-strings" do
      assert {:error, :unknown_rotation} = RotationAliases.resolve(nil)
    end

    test "every known rotation type resolves to itself" do
      for type <- ResidencySchedule.Rotations.all_rotation_types(), type != "unknown" do
        assert {:ok, ^type} = RotationAliases.resolve(type)
      end
    end
  end

  describe "weekend_counterparts/1" do
    test "night float maps to weekend nights only" do
      assert RotationAliases.weekend_counterparts("night_float") == ["strong_weekend_nights"]
    end
  end
end
