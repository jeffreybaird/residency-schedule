defmodule ResidencySchedule.Assistant.Chat.Providers.Anthropic.Accumulator do
  @moduledoc """
  Folds Messages API stream events into content blocks. `apply/2` returns
  the provider events to emit for each stream event; `finish/1` turns the
  accumulated blocks into an assistant `Message` and turn metadata.

  Blocks are kept in wire form (string keys) so the whole list can be sent
  back verbatim as the assistant turn, thinking blocks included.
  """

  alias ResidencySchedule.Assistant.Chat.{Message, ToolCall}

  defstruct blocks: %{}, stop: nil, usage: %{}, model: nil, error: nil

  @type t :: %__MODULE__{}

  @usage_keys ~w(input_tokens output_tokens cache_read_input_tokens cache_creation_input_tokens)

  @doc """
  An empty accumulator.

      iex> ResidencySchedule.Assistant.Chat.Providers.Anthropic.Accumulator.new().blocks
      %{}
  """
  def new, do: %__MODULE__{}

  @doc """
  Applies one decoded stream event. Returns the new state and the provider
  events to emit.

      iex> alias ResidencySchedule.Assistant.Chat.Providers.Anthropic.Accumulator
      iex> start = %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text", "text" => ""}}
      iex> delta = %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => "Hi"}}
      iex> {state, []} = Accumulator.apply(Accumulator.new(), start)
      iex> {_state, events} = Accumulator.apply(state, delta)
      iex> events
      [text_delta: "Hi"]
  """
  def apply(%__MODULE__{} = state, %{"type" => "message_start", "message" => message}) do
    {%{state | model: message["model"], usage: take_usage(message["usage"])}, []}
  end

  def apply(%__MODULE__{} = state, %{"type" => "content_block_start"} = event) do
    {put_block(state, event["index"], start_block(event["content_block"])), []}
  end

  def apply(%__MODULE__{} = state, %{"type" => "content_block_delta"} = event) do
    apply_delta(state, event["index"], event["delta"])
  end

  def apply(%__MODULE__{} = state, %{"type" => "content_block_stop", "index" => index}) do
    stop_block(state, index, state.blocks[index])
  end

  def apply(%__MODULE__{} = state, %{"type" => "message_delta"} = event) do
    usage = Map.merge(state.usage, take_usage(event["usage"]))
    {%{state | stop: stop_reason(event["delta"]), usage: usage}, []}
  end

  def apply(%__MODULE__{} = state, %{"type" => "error", "error" => error}) do
    {%{
       state
       | error: {:api_error, %{status: nil, type: error["type"], message: error["message"]}}
     }, []}
  end

  def apply(%__MODULE__{} = state, _other), do: {state, []}

  @doc """
  Builds the assistant message and metadata from the accumulated blocks.

      iex> alias ResidencySchedule.Assistant.Chat.Providers.Anthropic.Accumulator
      iex> events = [
      ...>   %{"type" => "message_start", "message" => %{"model" => "claude-sonnet-5", "usage" => %{"input_tokens" => 10}}},
      ...>   %{"type" => "content_block_start", "index" => 0, "content_block" => %{"type" => "text", "text" => ""}},
      ...>   %{"type" => "content_block_delta", "index" => 0, "delta" => %{"type" => "text_delta", "text" => "Hello"}},
      ...>   %{"type" => "content_block_stop", "index" => 0},
      ...>   %{"type" => "message_delta", "delta" => %{"stop_reason" => "end_turn"}, "usage" => %{"output_tokens" => 3}}
      ...> ]
      iex> state = Enum.reduce(events, Accumulator.new(), fn event, state -> {state, _} = Accumulator.apply(state, event); state end)
      iex> {:ok, message, meta} = Accumulator.finish(state)
      iex> {message.parts, message.raw, meta}
      {[text: "Hello"], [%{"type" => "text", "text" => "Hello"}], %{stop: :end_turn, usage: %{input_tokens: 10, output_tokens: 3}, model: "claude-sonnet-5"}}
  """
  def finish(%__MODULE__{error: {:api_error, _} = error}), do: {:error, error}

  def finish(%__MODULE__{} = state) do
    raw = ordered_blocks(state)
    message = Message.assistant(Enum.flat_map(raw, &to_part/1), raw)
    {:ok, message, %{stop: state.stop || :unknown, usage: state.usage, model: state.model}}
  end

  @doc """
  Maps the API's stop reason onto the provider-neutral atom.

      iex> ResidencySchedule.Assistant.Chat.Providers.Anthropic.Accumulator.stop_reason(%{"stop_reason" => "tool_use"})
      :tool_use

      iex> ResidencySchedule.Assistant.Chat.Providers.Anthropic.Accumulator.stop_reason(%{"stop_reason" => "refusal"})
      :refusal
  """
  def stop_reason(%{"stop_reason" => "end_turn"}), do: :end_turn
  def stop_reason(%{"stop_reason" => "stop_sequence"}), do: :end_turn
  def stop_reason(%{"stop_reason" => "tool_use"}), do: :tool_use
  def stop_reason(%{"stop_reason" => "max_tokens"}), do: :max_tokens
  def stop_reason(%{"stop_reason" => "refusal"}), do: :refusal
  def stop_reason(_delta), do: :unknown

  # ── Blocks ─────────────────────────────────────────────────────────────────

  defp start_block(%{"type" => "text"} = block), do: %{block | "text" => block["text"] || ""}

  defp start_block(%{"type" => "tool_use"} = block),
    do: block |> Map.delete("input") |> Map.put("partial_json", "")

  defp start_block(%{"type" => "thinking"} = block),
    do:
      Map.merge(block, %{"thinking" => block["thinking"] || "", "signature" => block["signature"]})

  defp start_block(block), do: block

  defp put_block(state, index, block), do: %{state | blocks: Map.put(state.blocks, index, block)}

  defp apply_delta(state, index, %{"type" => "text_delta", "text" => text}) do
    {append(state, index, "text", text), [{:text_delta, text}]}
  end

  defp apply_delta(state, index, %{"type" => "input_json_delta", "partial_json" => json}) do
    {append(state, index, "partial_json", json), []}
  end

  defp apply_delta(state, index, %{"type" => "thinking_delta", "thinking" => thinking}) do
    {append(state, index, "thinking", thinking), []}
  end

  defp apply_delta(state, index, %{"type" => "signature_delta", "signature" => signature}) do
    {update_block(state, index, &Map.put(&1, "signature", signature)), []}
  end

  defp apply_delta(state, _index, _delta), do: {state, []}

  defp append(state, index, key, value),
    do: update_block(state, index, &Map.update(&1, key, value, fn acc -> acc <> value end))

  defp update_block(state, index, fun) do
    %{state | blocks: Map.update(state.blocks, index, fun.(%{}), fun)}
  end

  defp stop_block(state, index, %{"type" => "tool_use", "partial_json" => json} = block) do
    case decode_input(json) do
      {:ok, input} ->
        block = block |> Map.delete("partial_json") |> Map.put("input", input)
        {put_block(state, index, block), [{:tool_call, to_tool_call(block)}]}

      :error ->
        {%{state | blocks: Map.delete(state.blocks, index)}, []}
    end
  end

  defp stop_block(state, _index, _block), do: {state, []}

  defp decode_input(""), do: {:ok, %{}}

  defp decode_input(json) do
    case Jason.decode(json) do
      {:ok, input} when is_map(input) -> {:ok, input}
      _ -> :error
    end
  end

  defp ordered_blocks(%__MODULE__{blocks: blocks}) do
    blocks
    |> Enum.sort_by(fn {index, _block} -> index end)
    |> Enum.map(fn {_index, block} -> block end)
  end

  defp to_part(%{"type" => "text", "text" => ""}), do: []
  defp to_part(%{"type" => "text", "text" => text}), do: [{:text, text}]
  defp to_part(%{"type" => "tool_use"} = block), do: [to_tool_call(block)]
  defp to_part(_block), do: []

  defp to_tool_call(block), do: ToolCall.new(block["id"], block["name"], block["input"])

  defp take_usage(nil), do: %{}

  defp take_usage(usage) do
    usage
    |> Map.take(@usage_keys)
    |> Map.new(fn {key, value} -> {String.to_existing_atom(key), value} end)
  end
end
