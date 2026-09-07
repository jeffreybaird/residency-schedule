defmodule ResidencySchedule.Assistant.Chat.ToolCallTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Assistant.Chat.ToolCall

  doctest ToolCall

  describe "new/3" do
    test "defaults args to an empty map" do
      assert ToolCall.new("toolu_1", "whoami").args == %{}
    end
  end
end
