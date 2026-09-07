defmodule ResidencySchedule.Assistant.Chat.MessageTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Assistant.Chat.{Message, ToolCall, ToolResult}

  doctest Message

  describe "assistant/2" do
    test "keeps the raw payload" do
      raw = [%{"type" => "text", "text" => "Hi"}]
      assert Message.assistant([{:text, "Hi"}], raw).raw == raw
    end
  end

  describe "text/1" do
    test "ignores tool calls and results" do
      call = ToolCall.new("toolu_1", "whoami")
      result = ToolResult.ok("toolu_1", "{}")
      assert Message.text(%Message{parts: [{:text, "a"}, call, result, {:text, "b"}]}) == "ab"
    end

    test "is empty for a message without text" do
      assert Message.text(Message.assistant([ToolCall.new("toolu_1", "whoami")])) == ""
    end
  end

  describe "tool_calls/1" do
    test "is empty for a text-only message" do
      assert Message.tool_calls(Message.user("Hi")) == []
    end
  end
end
