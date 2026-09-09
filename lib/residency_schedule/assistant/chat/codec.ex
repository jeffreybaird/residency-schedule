defmodule ResidencySchedule.Assistant.Chat.Codec do
  @moduledoc """
  Turns a conversation and its transcript into plain JSON-safe maps and back,
  so a chat can be stored as a database row and picked up after a restart.

  The stored form carries a `"version"` so a later change to the layout can
  be told apart from a row it can still read. The system prompt is not
  stored: it names today's date, so it is rebuilt when the chat is loaded.
  """

  alias ResidencySchedule.Assistant.Chat.{Conversation, Message, ToolCall, ToolResult, Transcript}

  @version 1

  # Stored as strings and mapped back through these lists rather than through
  # String.to_existing_atom/1: right after a restart the provider modules may
  # not have loaded yet, and their atoms with them.
  @stops [:end_turn, :tool_use, :max_tokens, :refusal, :unknown]
  @usage_keys [
    :input_tokens,
    :output_tokens,
    :cache_read_input_tokens,
    :cache_creation_input_tokens
  ]

  @doc """
  The stored form of a conversation and transcript.

      iex> alias ResidencySchedule.Assistant.Chat.{Codec, Conversation, Message, Toolbox.Empty, Transcript}
      iex> conversation = %{Conversation.new(toolbox: Empty) | messages: [Message.user("Hi")]}
      iex> transcript = Transcript.add(Transcript.new(), %{kind: :user, text: "Hi"})
      iex> data = Codec.dump(conversation, transcript)
      iex> {data["version"], data["messages"], data["transcript"]["entries"]}
      {1, [%{"role" => "user", "parts" => [%{"type" => "text", "text" => "Hi"}], "raw" => nil}], [%{"id" => 1, "kind" => "user", "text" => "Hi"}]}
  """
  def dump(%Conversation{} = conversation, %Transcript{} = transcript) do
    %{
      "version" => @version,
      "messages" => Enum.map(conversation.messages, &dump_message/1),
      "pending" => Enum.map(conversation.pending, &dump_part/1),
      "usage" => Map.new(conversation.usage, fn {key, value} -> {to_string(key), value} end),
      "last_stop" => conversation.last_stop && to_string(conversation.last_stop),
      "transcript" => %{
        "next_id" => transcript.next_id,
        "entries" => Enum.map(transcript.entries, &dump_entry/1)
      }
    }
  end

  @doc """
  Rebuilds a conversation and transcript from their stored form. `base` is
  a fresh conversation for the user; its toolbox, user, and system prompt
  are kept and the stored history is laid over it. Returns
  `{:error, :unreadable}` for a layout this version cannot read, or for a
  row that does not decode.

      iex> alias ResidencySchedule.Assistant.Chat.{Codec, Conversation, Message, Toolbox.Empty, Transcript}
      iex> conversation = %{Conversation.new(toolbox: Empty) | messages: [Message.user("Hi"), Message.assistant([{:text, "Hello."}])], last_stop: :end_turn}
      iex> transcript = Transcript.new() |> Transcript.add(%{kind: :user, text: "Hi"}) |> Transcript.append_text("Hello.")
      iex> data = Codec.dump(conversation, transcript)
      iex> {:ok, loaded, loaded_transcript} = Codec.load(data, Conversation.new(toolbox: Empty))
      iex> {loaded.messages == conversation.messages, loaded.last_stop, loaded_transcript == transcript}
      {true, :end_turn, true}
  """
  def load(%{"version" => @version} = data, %Conversation{} = base) do
    conversation = %{
      base
      | messages: Enum.map(data["messages"], &load_message/1),
        pending: Enum.map(data["pending"], &load_part/1),
        usage: load_usage(data["usage"]),
        last_stop: find_atom(@stops, data["last_stop"])
    }

    transcript = %Transcript{
      next_id: data["transcript"]["next_id"],
      entries: Enum.map(data["transcript"]["entries"], &load_entry/1)
    }

    {:ok, conversation, transcript}
  rescue
    _malformed -> {:error, :unreadable}
  end

  def load(_data, _base), do: {:error, :unreadable}

  # ── Messages ──────────────────────────────────────────────────────────────

  defp dump_message(%Message{role: role, parts: parts, raw: raw}) do
    %{"role" => to_string(role), "parts" => Enum.map(parts, &dump_part/1), "raw" => raw}
  end

  defp load_message(%{"role" => role, "parts" => parts, "raw" => raw}) do
    %Message{role: load_role(role), parts: Enum.map(parts, &load_part/1), raw: raw}
  end

  defp load_role("user"), do: :user
  defp load_role("assistant"), do: :assistant

  defp dump_part({:text, text}), do: %{"type" => "text", "text" => text}

  defp dump_part(%ToolCall{id: id, name: name, args: args}),
    do: %{"type" => "tool_call", "id" => id, "name" => name, "args" => args}

  defp dump_part(%ToolResult{call_id: call_id, content: content, error?: error?}),
    do: %{"type" => "tool_result", "call_id" => call_id, "content" => content, "error" => error?}

  defp load_part(%{"type" => "text", "text" => text}), do: {:text, text}

  defp load_part(%{"type" => "tool_call", "id" => id, "name" => name, "args" => args}),
    do: ToolCall.new(id, name, args)

  defp load_part(%{"type" => "tool_result", "call_id" => id, "content" => content, "error" => e}),
    do: %ToolResult{call_id: id, content: content, error?: e}

  defp load_usage(usage) do
    for {key, value} <- usage, atom = find_atom(@usage_keys, key), into: %{}, do: {atom, value}
  end

  defp find_atom(_known, nil), do: nil
  defp find_atom(known, name), do: Enum.find(known, &(to_string(&1) == name))

  # ── Transcript ────────────────────────────────────────────────────────────

  defp dump_entry(%{id: id, kind: :tool, call: call, result: result}) do
    %{
      "id" => id,
      "kind" => "tool",
      "call" => dump_part(call),
      "result" => result && dump_part(result)
    }
  end

  defp dump_entry(%{id: id, kind: kind, text: text}),
    do: %{"id" => id, "kind" => to_string(kind), "text" => text}

  defp load_entry(%{"id" => id, "kind" => "tool", "call" => call, "result" => result}) do
    %{id: id, kind: :tool, call: load_part(call), result: result && load_part(result)}
  end

  defp load_entry(%{"id" => id, "kind" => "user", "text" => text}),
    do: %{id: id, kind: :user, text: text}

  defp load_entry(%{"id" => id, "kind" => "assistant", "text" => text}),
    do: %{id: id, kind: :assistant, text: text}
end
