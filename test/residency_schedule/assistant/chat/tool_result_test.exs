defmodule ResidencySchedule.Assistant.Chat.ToolResultTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Assistant.Chat.ToolResult

  doctest ToolResult

  describe "ok/2" do
    test "keeps the content" do
      assert ToolResult.ok("toolu_1", "[]").content == "[]"
    end
  end

  describe "error/2" do
    test "keeps the call id and content" do
      result = ToolResult.error("toolu_1", "nope")
      assert {result.call_id, result.content, result.error?} == {"toolu_1", "nope", true}
    end
  end
end
