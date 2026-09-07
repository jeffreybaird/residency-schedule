defmodule ResidencySchedule.Assistant.Chat.ToolCall do
  @moduledoc """
  A request from the model to run one tool. `id` is the provider's call id
  and must be echoed back on the matching `ToolResult`.
  """

  @enforce_keys [:id, :name]
  defstruct [:id, :name, args: %{}]

  @type t :: %__MODULE__{id: String.t(), name: String.t(), args: map}

  @doc """
  Builds a tool call.

      iex> call = ResidencySchedule.Assistant.Chat.ToolCall.new("toolu_1", "who_is_on", %{"rotation" => "onc"})
      iex> {call.name, call.args["rotation"]}
      {"who_is_on", "onc"}
  """
  def new(id, name, args \\ %{}) when is_binary(id) and is_binary(name) and is_map(args) do
    %__MODULE__{id: id, name: name, args: args}
  end
end
