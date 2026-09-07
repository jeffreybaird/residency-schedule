defmodule ResidencySchedule.Assistant.Chat.RequestTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Assistant.Chat.Request

  doctest Request

  describe "new/1" do
    test "defaults every field" do
      assert Request.new([]) == %Request{system: "", messages: [], tools: []}
    end

    test "rejects unknown keys" do
      assert_raise KeyError, fn -> Request.new(model: "x") end
    end
  end
end
