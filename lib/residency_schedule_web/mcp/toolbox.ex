defmodule ResidencyScheduleWeb.MCP.Toolbox do
  @moduledoc """
  Exposes the MCP tool catalogue to the chat loop, so both surfaces serve
  one list of tools with one dispatcher.
  """

  @behaviour ResidencySchedule.Assistant.Chat.Toolbox

  alias ResidencySchedule.Assistant.Chat.{Tool, ToolCall, ToolResult}
  alias ResidencyScheduleWeb.MCP.Tools

  @doc """
  Every MCP tool as a chat tool.

      iex> ResidencyScheduleWeb.MCP.Toolbox.tools() |> Enum.map(& &1.name) |> Enum.take(2)
      ["whoami", "find_resident"]
  """
  @impl true
  def tools, do: Enum.map(Tools.definitions(), &to_tool/1)

  @doc """
  Converts one MCP definition to a chat tool.

      iex> definition = %{name: "x", description: "d", inputSchema: %{type: "object", properties: %{}, required: []}}
      iex> ResidencyScheduleWeb.MCP.Toolbox.to_tool(definition).input_schema.type
      "object"
  """
  def to_tool(%{name: name, description: description, inputSchema: schema}),
    do: Tool.new(name, description, schema)

  @doc """
  Whether a tool changes data, from its MCP `readOnlyHint`. Unknown tools
  count as mutating.

      iex> ResidencyScheduleWeb.MCP.Toolbox.mutating?("who_is_on")
      false

      iex> ResidencyScheduleWeb.MCP.Toolbox.mutating?("request_coverage")
      true
  """
  @impl true
  def mutating?(name) do
    Tools.definitions()
    |> Enum.find(&(&1.name == name))
    |> read_only?()
    |> Kernel.not()
  end

  @doc """
  Runs one call through the MCP dispatcher for the user.

  Exempt from doctest — most tools hit the database. See `ToolboxTest`.
  """
  @impl true
  def run(%ToolCall{} = call, user) do
    case Tools.call(call.name, call.args, user) do
      {:ok, %{isError: true, content: content}} -> ToolResult.error(call.id, text(content))
      {:ok, %{content: content}} -> ToolResult.ok(call.id, text(content))
      {:error, :unknown_tool} -> ToolResult.error(call.id, "Unknown tool: #{call.name}")
    end
  end

  defp read_only?(nil), do: false
  defp read_only?(%{annotations: %{readOnlyHint: read_only}}), do: read_only

  defp text(content), do: Enum.map_join(content, "\n", & &1.text)
end
