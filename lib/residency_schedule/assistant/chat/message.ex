defmodule ResidencySchedule.Assistant.Chat.Message do
  @moduledoc """
  One turn of a conversation, independent of any provider.

  `parts` is an ordered list of `{:text, string}`, `ToolCall`, and
  `ToolResult`. `raw` is the provider's own representation of an assistant
  turn (for Anthropic, the content blocks including thinking); an adapter
  replays it verbatim so provider-specific blocks survive the round trip.
  """

  alias ResidencySchedule.Assistant.Chat.{ToolCall, ToolResult}

  defstruct role: :user, parts: [], raw: nil

  @type part :: {:text, String.t()} | ToolCall.t() | ToolResult.t()
  @type t :: %__MODULE__{role: :user | :assistant, parts: [part], raw: term}

  @doc """
  A user turn containing text.

      iex> msg = ResidencySchedule.Assistant.Chat.Message.user("Who is on onc today?")
      iex> {msg.role, msg.parts}
      {:user, [text: "Who is on onc today?"]}
  """
  def user(text) when is_binary(text), do: %__MODULE__{role: :user, parts: [{:text, text}]}

  @doc """
  An assistant turn. `raw` is the provider payload to replay, if any.

      iex> alias ResidencySchedule.Assistant.Chat.ToolCall
      iex> call = ToolCall.new("toolu_1", "who_is_on", %{"rotation" => "onc"})
      iex> msg = ResidencySchedule.Assistant.Chat.Message.assistant([{:text, "Checking."}, call])
      iex> {msg.role, msg.raw}
      {:assistant, nil}
  """
  def assistant(parts, raw \\ nil) when is_list(parts) do
    %__MODULE__{role: :assistant, parts: parts, raw: raw}
  end

  @doc """
  A user turn carrying tool results back to the model.

      iex> alias ResidencySchedule.Assistant.Chat.ToolResult
      iex> msg = ResidencySchedule.Assistant.Chat.Message.tool_results([ToolResult.ok("toolu_1", "[]")])
      iex> {msg.role, length(msg.parts)}
      {:user, 1}
  """
  def tool_results([%ToolResult{} | _] = results), do: %__MODULE__{role: :user, parts: results}

  @doc """
  The text of a message, with text parts joined.

      iex> msg = ResidencySchedule.Assistant.Chat.Message.assistant([{:text, "Hello"}, {:text, " there"}])
      iex> ResidencySchedule.Assistant.Chat.Message.text(msg)
      "Hello there"
  """
  def text(%__MODULE__{parts: parts}) do
    parts
    |> Enum.flat_map(&text_part/1)
    |> Enum.join()
  end

  @doc """
  The tool calls in a message, in order.

      iex> alias ResidencySchedule.Assistant.Chat.ToolCall
      iex> call = ToolCall.new("toolu_1", "who_is_on", %{"rotation" => "onc"})
      iex> msg = ResidencySchedule.Assistant.Chat.Message.assistant([{:text, "Checking."}, call])
      iex> ResidencySchedule.Assistant.Chat.Message.tool_calls(msg) |> Enum.map(& &1.name)
      ["who_is_on"]
  """
  def tool_calls(%__MODULE__{parts: parts}), do: Enum.filter(parts, &match?(%ToolCall{}, &1))

  defp text_part({:text, text}), do: [text]
  defp text_part(_other), do: []
end
