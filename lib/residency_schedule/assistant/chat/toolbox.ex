defmodule ResidencySchedule.Assistant.Chat.Toolbox do
  @moduledoc """
  The tools a conversation may call. The loop only knows this behaviour, so
  the catalogue can live wherever the tools do (today, next to the MCP
  server) without the loop depending on it.

  `mutating?/1` decides which calls need the user's approval before they
  run. Unknown names should be treated as mutating.
  """

  alias ResidencySchedule.Assistant.Chat.{Tool, ToolCall, ToolResult}

  @callback tools() :: [Tool.t()]
  @callback mutating?(name :: String.t()) :: boolean
  @callback run(ToolCall.t(), user :: term) :: ToolResult.t()
end
