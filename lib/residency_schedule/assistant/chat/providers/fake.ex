defmodule ResidencySchedule.Assistant.Chat.Providers.Fake do
  @moduledoc """
  A scripted provider for tests. No network, deterministic output.

  A script is a list of turns consumed in order. Each turn is one of:

    * `{:text, "reply"}` — streams the text and stops with `:end_turn`
    * `{:text, "reply", :max_tokens}` — same, with an explicit stop reason
    * `{:tool_calls, "lead-in text" | nil, [ToolCall.t()]}` — streams the
      text, then each call, and stops with `:tool_use`
    * `{:error, reason}` — the turn fails with `{:error, reason}`
    * a 1-arity function of the `Request` returning one of the above

  Register a script for the current test with `script/1`; it is found from
  any process spawned by the test (LiveViews included) via `$callers`. When
  no script is registered, the `:script` config key is used as a single turn
  applied to every request, and with neither the reply echoes the last user
  message.
  """

  @behaviour ResidencySchedule.Assistant.Chat.Provider

  alias ResidencySchedule.Assistant.Chat.{Message, Request}

  @key {__MODULE__, :script}

  @doc """
  Registers a script for the calling process and its callees. Returns the
  agent holding the remaining turns.

      iex> alias ResidencySchedule.Assistant.Chat.{Message, Providers.Fake, Request}
      iex> {:ok, _agent} = Fake.script([{:text, "First"}, {:text, "Second"}])
      iex> request = Request.new(messages: [Message.user("Hi")])
      iex> {:ok, first, _meta} = Fake.stream(request, [], fn _event -> :ok end)
      iex> {:ok, second, _meta} = Fake.stream(request, [], fn _event -> :ok end)
      iex> {Message.text(first), Message.text(second)}
      {"First", "Second"}
  """
  def script(turns) when is_list(turns) do
    {:ok, agent} = Agent.start_link(fn -> turns end)
    Process.put(@key, agent)
    {:ok, agent}
  end

  @doc """
  Plays the next scripted turn, emitting events as a real provider would.

      iex> alias ResidencySchedule.Assistant.Chat.{Message, Providers.Fake, Request, ToolCall}
      iex> call = ToolCall.new("toolu_1", "who_is_on", %{"rotation" => "onc"})
      iex> request = Request.new(messages: [Message.user("Who is on onc?")])
      iex> config = [script: {:tool_calls, "Checking.", [call]}]
      iex> {:ok, reply, meta} = Fake.stream(request, config, fn _event -> :ok end)
      iex> {Message.text(reply), length(Message.tool_calls(reply)), meta.stop}
      {"Checking.", 1, :tool_use}
  """
  @impl true
  def stream(%Request{} = request, config, on_event) when is_function(on_event, 1) do
    request
    |> next_turn(config)
    |> resolve_turn(request)
    |> play(on_event)
  end

  defp next_turn(request, config) do
    case find_agent() do
      {:ok, agent} -> pop_turn(agent)
      :none -> Keyword.get(config, :script, {:echo, request})
    end
  end

  defp find_agent do
    [self() | Process.get(:"$callers", [])]
    |> Enum.find_value(:none, &agent_in(&1))
  end

  defp agent_in(pid) do
    case pid |> Process.info(:dictionary) |> dictionary_value() do
      nil -> nil
      agent -> {:ok, agent}
    end
  end

  defp dictionary_value({:dictionary, dictionary}) do
    case List.keyfind(dictionary, @key, 0) do
      {@key, agent} -> agent
      nil -> nil
    end
  end

  defp dictionary_value(nil), do: nil

  defp pop_turn(agent) do
    Agent.get_and_update(agent, fn
      [] -> {{:error, :script_exhausted}, []}
      [turn | rest] -> {turn, rest}
    end)
  end

  defp resolve_turn(fun, request) when is_function(fun, 1), do: fun.(request)
  defp resolve_turn({:echo, request}, _request), do: {:text, "fake: " <> last_user_text(request)}
  defp resolve_turn(turn, _request), do: turn

  defp last_user_text(%Request{messages: messages}) do
    messages
    |> Enum.reverse()
    |> Enum.find_value("", &user_text/1)
  end

  defp user_text(%Message{role: :user} = message), do: Message.text(message)
  defp user_text(_message), do: nil

  defp play({:error, reason}, _on_event), do: {:error, reason}
  defp play({:text, text}, on_event), do: play({:text, text, :end_turn}, on_event)

  defp play({:text, text, stop}, on_event) do
    emit_text(text, on_event)
    finish([{:text, text}], stop, on_event)
  end

  defp play({:tool_calls, text, calls}, on_event) do
    emit_text(text, on_event)
    Enum.each(calls, &on_event.({:tool_call, &1}))
    finish(text_part(text) ++ calls, :tool_use, on_event)
  end

  defp emit_text(nil, _on_event), do: :ok

  defp emit_text(text, on_event) do
    ~r/(?<=\s)/
    |> Regex.split(text, trim: true)
    |> Enum.each(&on_event.({:text_delta, &1}))
  end

  defp text_part(nil), do: []
  defp text_part(text), do: [{:text, text}]

  defp finish(parts, stop, on_event) do
    meta = %{stop: stop, usage: %{input_tokens: 0, output_tokens: 0}, model: "fake"}
    on_event.({:done, meta})
    {:ok, Message.assistant(parts), meta}
  end
end
