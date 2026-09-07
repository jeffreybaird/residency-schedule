defmodule ResidencySchedule.Assistant.Chat.Conversation do
  @moduledoc """
  One chat with the model: history, tool dispatch, and the approval gate.

  A `send/3` runs the model, executes any read-only tool calls it makes, and
  keeps going until the model answers in text. When a turn includes a call
  the toolbox marks as mutating, the loop stops with the calls in `pending`
  and emits `{:approval_required, calls}`; the caller decides with
  `approve/2` or `deny/2`, and the loop resumes.

  Events reach the callback as the loop runs: every provider event
  (`text_delta`, `tool_call`, `done`), plus `{:tool_result, call, result}`
  after each tool runs and `{:approval_required, [call]}` at the gate.

  Failures return `{:error, reason, conversation}`. The history stays valid
  at every failure point, so the caller can keep or drop the conversation.
  """

  alias ResidencySchedule.Assistant.Chat.{Message, Prompt, Provider, Request, ToolResult}
  alias ResidencySchedule.Assistant.LocalDate

  @enforce_keys [:toolbox]
  defstruct toolbox: nil,
            user: nil,
            system: "",
            messages: [],
            pending: [],
            usage: %{},
            last_stop: nil,
            max_tool_rounds: 10

  @type t :: %__MODULE__{}

  @declined "The user declined this action. Do not retry it; ask what they would like instead."
  @limit "Tool call limit reached for this message. Answer with what you have."

  @doc """
  Starts a conversation. `:toolbox` is required; `:system` defaults to the
  standard prompt for today; `:user` is passed to every tool run.

      iex> alias ResidencySchedule.Assistant.Chat.{Conversation, Toolbox.Empty}
      iex> conversation = Conversation.new(toolbox: Empty, system: "Be terse.")
      iex> {conversation.system, conversation.messages, Conversation.awaiting_approval?(conversation)}
      {"Be terse.", [], false}
  """
  def new(opts) when is_list(opts) do
    opts
    |> Keyword.put_new_lazy(:system, fn -> Prompt.system(LocalDate.today()) end)
    |> then(&struct!(__MODULE__, &1))
  end

  @doc """
  Whether the loop is paused on mutating tool calls.

      iex> alias ResidencySchedule.Assistant.Chat.{Conversation, ToolCall, Toolbox.Empty}
      iex> conversation = %{Conversation.new(toolbox: Empty) | pending: [ToolCall.new("toolu_1", "request_coverage")]}
      iex> Conversation.awaiting_approval?(conversation)
      true
  """
  def awaiting_approval?(%__MODULE__{pending: pending}), do: pending != []

  @doc """
  Sends a user message and runs the loop until the model answers or needs
  approval.

      iex> alias ResidencySchedule.Assistant.Chat.{Conversation, Message, Providers.Fake, Toolbox.Empty}
      iex> Fake.script([{:text, "Nora is on onc."}])
      iex> conversation = Conversation.new(toolbox: Empty, system: "Be terse.")
      iex> {:ok, conversation} = Conversation.send(conversation, "Who is on onc?", fn _event -> :ok end)
      iex> conversation.messages |> List.last() |> Message.text()
      "Nora is on onc."
  """
  def send(%__MODULE__{pending: [_ | _]} = conversation, _text, _on_event),
    do: {:error, :awaiting_approval, conversation}

  def send(%__MODULE__{} = conversation, text, on_event)
      when is_binary(text) and is_function(on_event, 1) do
    conversation
    |> append(Message.user(text))
    |> step(on_event, 0)
  end

  @doc """
  Runs the pending calls and resumes the loop.

      iex> alias ResidencySchedule.Assistant.Chat.{Conversation, Message, Providers.Fake, ToolCall, Toolbox.Empty}
      iex> Fake.script([{:text, "Done."}])
      iex> call = ToolCall.new("toolu_1", "request_coverage", %{})
      iex> conversation = %{Conversation.new(toolbox: Empty) | pending: [call]}
      iex> {:ok, conversation} = Conversation.approve(conversation, fn _event -> :ok end)
      iex> {Conversation.awaiting_approval?(conversation), conversation.messages |> List.last() |> Message.text()}
      {false, "Done."}
  """
  def approve(%__MODULE__{pending: []} = conversation, _on_event),
    do: {:error, :nothing_pending, conversation}

  def approve(%__MODULE__{pending: calls} = conversation, on_event)
      when is_function(on_event, 1) do
    %{conversation | pending: []}
    |> run_calls(calls, on_event)
    |> step(on_event, 0)
  end

  @doc """
  Declines the pending mutating calls, still runs any read-only calls in
  the same batch, and lets the model respond.

      iex> alias ResidencySchedule.Assistant.Chat.{Conversation, Message, Providers.Fake, ToolCall, Toolbox.Empty}
      iex> Fake.script([{:text, "Understood, I will not file it."}])
      iex> call = ToolCall.new("toolu_1", "request_coverage", %{})
      iex> conversation = %{Conversation.new(toolbox: Empty) | pending: [call]}
      iex> {:ok, conversation} = Conversation.deny(conversation, fn _event -> :ok end)
      iex> conversation.messages |> Enum.at(-2) |> Map.fetch!(:parts) |> hd() |> Map.fetch!(:error?)
      true
  """
  def deny(%__MODULE__{pending: []} = conversation, _on_event),
    do: {:error, :nothing_pending, conversation}

  def deny(%__MODULE__{pending: calls} = conversation, on_event) when is_function(on_event, 1) do
    %{conversation | pending: []}
    |> resolve_calls(calls, on_event, &decline_or_run/3)
    |> step(on_event, 0)
  end

  # ── Loop ───────────────────────────────────────────────────────────────────

  defp step(conversation, on_event, rounds) do
    case Provider.stream(request(conversation), on_event) do
      {:ok, message, meta} ->
        conversation
        |> append(message)
        |> record_meta(meta)
        |> after_turn(meta.stop, on_event, rounds)

      {:error, reason} ->
        {:error, reason, conversation}
    end
  end

  defp request(%__MODULE__{} = conversation) do
    Request.new(
      system: conversation.system,
      messages: conversation.messages,
      tools: conversation.toolbox.tools()
    )
  end

  defp after_turn(conversation, :tool_use, on_event, rounds) do
    conversation.messages
    |> List.last()
    |> Message.tool_calls()
    |> handle_calls(conversation, on_event, rounds)
  end

  defp after_turn(conversation, _stop, _on_event, _rounds), do: {:ok, conversation}

  defp handle_calls([], conversation, _on_event, _rounds), do: {:ok, conversation}

  defp handle_calls(calls, %{max_tool_rounds: max} = conversation, on_event, rounds)
       when rounds >= max do
    conversation =
      resolve_calls(conversation, calls, on_event, fn _c, call, _e -> limit(call) end)

    {:error, :max_tool_rounds, conversation}
  end

  defp handle_calls(calls, conversation, on_event, rounds) do
    if Enum.any?(calls, &conversation.toolbox.mutating?(&1.name)) do
      on_event.({:approval_required, calls})
      {:ok, %{conversation | pending: calls}}
    else
      conversation
      |> run_calls(calls, on_event)
      |> step(on_event, rounds + 1)
    end
  end

  # ── Tools ──────────────────────────────────────────────────────────────────

  defp run_calls(conversation, calls, on_event),
    do: resolve_calls(conversation, calls, on_event, &run/3)

  defp resolve_calls(conversation, calls, on_event, resolver) do
    calls
    |> Enum.map(&resolve_call(conversation, &1, on_event, resolver))
    |> Message.tool_results()
    |> then(&append(conversation, &1))
  end

  defp resolve_call(conversation, call, on_event, resolver) do
    result = resolver.(conversation, call, on_event)
    on_event.({:tool_result, call, result})
    result
  end

  defp run(conversation, call, _on_event), do: conversation.toolbox.run(call, conversation.user)

  defp decline_or_run(conversation, call, on_event) do
    if conversation.toolbox.mutating?(call.name),
      do: ToolResult.error(call.id, @declined),
      else: run(conversation, call, on_event)
  end

  defp limit(call), do: ToolResult.error(call.id, @limit)

  # ── State ──────────────────────────────────────────────────────────────────

  defp append(conversation, message),
    do: %{conversation | messages: conversation.messages ++ [message]}

  defp record_meta(conversation, meta) do
    %{
      conversation
      | last_stop: meta.stop,
        usage: Map.merge(conversation.usage, meta.usage, fn _key, a, b -> a + b end)
    }
  end
end
