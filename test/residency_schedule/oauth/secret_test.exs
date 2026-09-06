defmodule ResidencySchedule.OAuth.SecretTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.OAuth.Secret

  doctest Secret

  describe "generate/1" do
    test "produces distinct values" do
      assert Secret.generate() != Secret.generate()
    end

    test "is URL safe" do
      assert Secret.generate() =~ ~r/^[A-Za-z0-9_-]+$/
    end
  end

  describe "matches?/2" do
    test "returns false for nil secret" do
      refute Secret.matches?(nil, Secret.hash("x"))
    end

    test "returns false for nil hash" do
      refute Secret.matches?("x", nil)
    end
  end
end
