defmodule ResidencySchedule.Assistant.Chat.Toolbox.Empty do
  @moduledoc """
  A toolbox with no tools, for text-only conversations and tests.
  """

  @behaviour ResidencySchedule.Assistant.Chat.Toolbox

  alias ResidencySchedule.Assistant.Chat.{ToolCall, ToolResult}

  @doc """
  No tools.

      iex> ResidencySchedule.Assistant.Chat.Toolbox.Empty.tools()
      []
  """
  @impl true
  def tools, do: []

  @doc """
  Every name is treated as mutating, since none is known.

      iex> ResidencySchedule.Assistant.Chat.Toolbox.Empty.mutating?("anything")
      true
  """
  @impl true
  def mutating?(_name), do: true

  @doc """
  Every call fails as unknown.

      iex> call = ResidencySchedule.Assistant.Chat.ToolCall.new("toolu_1", "who_is_on")
      iex> ResidencySchedule.Assistant.Chat.Toolbox.Empty.run(call, nil).content
      "Unknown tool: who_is_on"
  """
  @impl true
  def run(%ToolCall{} = call, _user), do: ToolResult.error(call.id, "Unknown tool: #{call.name}")
end
