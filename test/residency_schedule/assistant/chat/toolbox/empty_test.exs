defmodule ResidencySchedule.Assistant.Chat.Toolbox.EmptyTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Assistant.Chat.Toolbox.Empty
  alias ResidencySchedule.Assistant.Chat.ToolCall

  doctest Empty

  test "run marks the result as an error" do
    call = ToolCall.new("toolu_1", "whoami")
    assert Empty.run(call, nil).error?
  end
end
