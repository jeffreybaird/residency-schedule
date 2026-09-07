defmodule ResidencySchedule.Assistant.Chat.ToolResult do
  @moduledoc """
  The outcome of running one `ToolCall`, sent back to the model as text.
  """

  @enforce_keys [:call_id, :content]
  defstruct [:call_id, :content, error?: false]

  @type t :: %__MODULE__{call_id: String.t(), content: String.t(), error?: boolean}

  @doc """
  A successful result.

      iex> result = ResidencySchedule.Assistant.Chat.ToolResult.ok("toolu_1", ~s({"residents": []}))
      iex> {result.call_id, result.error?}
      {"toolu_1", false}
  """
  def ok(call_id, content) when is_binary(call_id) and is_binary(content) do
    %__MODULE__{call_id: call_id, content: content, error?: false}
  end

  @doc """
  A failed result. The model sees the message and may recover.

      iex> result = ResidencySchedule.Assistant.Chat.ToolResult.error("toolu_1", "No resident named Tiff.")
      iex> result.error?
      true
  """
  def error(call_id, content) when is_binary(call_id) and is_binary(content) do
    %__MODULE__{call_id: call_id, content: content, error?: true}
  end
end
