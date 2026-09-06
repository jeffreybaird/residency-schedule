defmodule ResidencyScheduleWeb.MCP.Server do
  @moduledoc """
  Stateless MCP server core: takes one decoded JSON-RPC message plus the
  authenticated user and produces the reply. Supports `initialize`, `ping`,
  `tools/list`, and `tools/call`; every notification is accepted and ignored.
  """

  alias ResidencyScheduleWeb.MCP.{JsonRpc, Tools}

  @protocol_versions ["2025-06-18", "2025-03-26", "2024-11-05"]
  @default_version "2025-06-18"

  @doc """
  Protocol versions this server speaks, newest first.

      iex> hd(ResidencyScheduleWeb.MCP.Server.protocol_versions())
      "2025-06-18"
  """
  def protocol_versions, do: @protocol_versions

  @doc """
  Handles one message. Returns `{:reply, map}` for requests, `:accepted`
  for notifications and responses, or `{:invalid, map}` for malformed input
  (the map is a JSON-RPC error with a nil id).

      iex> msg = %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}
      iex> ResidencyScheduleWeb.MCP.Server.handle(msg, %ResidencySchedule.Accounts.User{})
      {:reply, %{jsonrpc: "2.0", id: 1, result: %{}}}

      iex> msg = %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}
      iex> ResidencyScheduleWeb.MCP.Server.handle(msg, %ResidencySchedule.Accounts.User{})
      :accepted
  """
  def handle(message, user) do
    case JsonRpc.classify(message) do
      {:request, id, method, params} -> {:reply, dispatch(id, method, params, user)}
      {:notification, _method, _params} -> :accepted
      :response -> :accepted
      :invalid -> {:invalid, JsonRpc.error(nil, :invalid_request, "Not a JSON-RPC 2.0 request")}
    end
  end

  @doc """
  Negotiates the protocol version: the client's version if supported, else
  the server's latest.

      iex> ResidencyScheduleWeb.MCP.Server.negotiate_version("2025-03-26")
      "2025-03-26"

      iex> ResidencyScheduleWeb.MCP.Server.negotiate_version("1999-01-01")
      "2025-06-18"
  """
  def negotiate_version(requested) when requested in @protocol_versions, do: requested
  def negotiate_version(_requested), do: @default_version

  defp dispatch(id, "initialize", params, _user) do
    JsonRpc.result(id, %{
      protocolVersion: negotiate_version(params["protocolVersion"]),
      capabilities: %{tools: %{listChanged: false}},
      serverInfo: %{name: "residency-schedule", version: "1.0.0"},
      instructions:
        "Schedule assistant for the OB/GYN residency. Names may be first names; dates are YYYY-MM-DD in America/New_York. " <>
          "Use check_coverage before request_coverage. Duty-hour results are estimates."
    })
  end

  defp dispatch(id, "ping", _params, _user), do: JsonRpc.result(id, %{})

  defp dispatch(id, "tools/list", _params, _user),
    do: JsonRpc.result(id, %{tools: Tools.definitions()})

  defp dispatch(id, "tools/call", %{"name" => name} = params, user) when is_binary(name) do
    case Tools.call(name, Map.get(params, "arguments") || %{}, user) do
      {:ok, result} -> JsonRpc.result(id, result)
      {:error, :unknown_tool} -> JsonRpc.error(id, :invalid_params, "Unknown tool: #{name}")
    end
  end

  defp dispatch(id, "tools/call", _params, _user),
    do: JsonRpc.error(id, :invalid_params, "tools/call requires a tool name")

  defp dispatch(id, method, _params, _user),
    do: JsonRpc.error(id, :method_not_found, "Method not found: #{method}")
end
