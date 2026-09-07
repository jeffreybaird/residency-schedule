defmodule ResidencySchedule.Assistant.Chat.ProviderTest do
  use ExUnit.Case, async: false

  alias ResidencySchedule.Assistant.Chat.{Message, Provider, Providers.Fake, Request}

  doctest Provider

  describe "current/0" do
    test "errors when no provider is configured" do
      with_chat_config([model: "fake"], fn ->
        assert Provider.current() == {:error, :chat_not_configured}
      end)
    end

    test "errors when the chat config is absent" do
      with_chat_config(nil, fn ->
        assert Provider.current() == {:error, :chat_not_configured}
      end)
    end
  end

  describe "stream/2" do
    test "delegates to the configured adapter with its config" do
      request = Request.new(messages: [Message.user("Hi")])
      Fake.script([{:text, "Scripted"}])

      assert {:ok, reply, %{stop: :end_turn}} =
               Provider.stream(request, &send(self(), {:event, &1}))

      assert Message.text(reply) == "Scripted"
      assert_received {:event, {:text_delta, "Scripted"}}
      assert_received {:event, {:done, %{stop: :end_turn}}}
    end

    test "returns the configuration error" do
      with_chat_config(nil, fn ->
        request = Request.new(messages: [Message.user("Hi")])
        assert Provider.stream(request, fn _ -> :ok end) == {:error, :chat_not_configured}
      end)
    end
  end

  defp with_chat_config(config, fun) do
    original = Application.get_env(:residency_schedule, :chat)
    put_chat_config(config)

    try do
      fun.()
    after
      put_chat_config(original)
    end
  end

  defp put_chat_config(nil), do: Application.delete_env(:residency_schedule, :chat)
  defp put_chat_config(config), do: Application.put_env(:residency_schedule, :chat, config)
end
