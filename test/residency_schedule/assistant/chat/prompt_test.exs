defmodule ResidencySchedule.Assistant.Chat.PromptTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Assistant.Chat.Prompt

  doctest Prompt

  test "names the tools the model must call first" do
    prompt = Prompt.system(~D[2026-09-07])
    assert prompt =~ "call whoami first"
    assert prompt =~ "check_coverage before request_coverage"
  end

  test "is identical for the same day" do
    assert Prompt.system(~D[2026-09-07]) == Prompt.system(~D[2026-09-07])
  end
end
