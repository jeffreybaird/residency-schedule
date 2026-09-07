defmodule ResidencySchedule.Assistant.ChatTest do
  use ExUnit.Case, async: false

  alias ResidencySchedule.Assistant.Chat

  doctest Chat

  describe "enabled?/0" do
    test "is false in demo mode even when configured on" do
      with_env(:demo_mode, true, fn -> refute Chat.enabled?() end)
    end

    test "is false when the chat config says so" do
      with_chat(Keyword.put(chat_config(), :enabled, false), fn -> refute Chat.enabled?() end)
    end

    test "is false when the enabled key is missing" do
      with_chat(Keyword.delete(chat_config(), :enabled), fn -> refute Chat.enabled?() end)
    end
  end

  describe "daily_limit/0" do
    test "reads the configured limit" do
      with_chat(Keyword.put(chat_config(), :daily_message_limit, 3), fn ->
        assert Chat.daily_limit() == 3
      end)
    end

    test "defaults when unset" do
      with_chat(Keyword.delete(chat_config(), :daily_message_limit), fn ->
        assert Chat.daily_limit() == 50
      end)
    end
  end

  defp chat_config, do: Application.get_env(:residency_schedule, :chat, [])
  defp with_chat(config, fun), do: with_env(:chat, config, fun)

  defp with_env(key, value, fun) do
    original = Application.get_env(:residency_schedule, key)
    Application.put_env(:residency_schedule, key, value)

    try do
      fun.()
    after
      Application.put_env(:residency_schedule, key, original)
    end
  end
end
