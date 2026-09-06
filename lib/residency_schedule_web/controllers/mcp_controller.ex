defmodule ResidencyScheduleWeb.MCPController do
  @moduledoc """
  Streamable HTTP transport for the MCP server (single endpoint, POST only).
  Requests get one JSON response; notifications get 202. GET (server-initiated
  SSE) and DELETE (session teardown) are not offered, which the spec allows
  via 405. The server is stateless, so no `Mcp-Session-Id` is issued.
  """
  use ResidencyScheduleWeb, :controller

  alias ResidencyScheduleWeb.MCP.{JsonRpc, Server}

  plug :verify_origin
  plug :verify_protocol_version

  @doc """
  Handles a JSON-RPC message posted by the client.

  Exempt from doctest — controller action.
  """
  def create(conn, %{"_json" => _batch}) do
    error(conn, 400, :invalid_request, "JSON-RPC batches are not supported")
  end

  def create(conn, params) do
    case Server.handle(params, conn.assigns.current_user) do
      {:reply, reply} -> json(conn, reply)
      :accepted -> send_resp(conn, 202, "")
      {:invalid, reply} -> conn |> put_status(400) |> json(reply)
    end
  end

  @doc """
  GET and DELETE are not supported on this endpoint.

  Exempt from doctest — controller action.
  """
  def not_allowed(conn, _params) do
    conn
    |> put_resp_header("allow", "POST")
    |> send_resp(405, "")
  end

  # MCP servers must validate Origin to defeat DNS rebinding. Browsers send it;
  # server-side MCP clients normally do not. A present Origin must match our host.
  defp verify_origin(conn, _opts) do
    case get_req_header(conn, "origin") do
      [] -> conn
      [origin] -> if same_host?(origin, conn), do: conn, else: reject_origin(conn)
      _ -> reject_origin(conn)
    end
  end

  defp same_host?(origin, conn) do
    case URI.parse(origin) do
      %URI{host: host} when is_binary(host) -> String.downcase(host) == String.downcase(conn.host)
      _ -> false
    end
  end

  defp reject_origin(conn) do
    conn
    |> send_resp(403, "Origin not allowed")
    |> halt()
  end

  defp verify_protocol_version(conn, _opts) do
    case get_req_header(conn, "mcp-protocol-version") do
      [] ->
        conn

      [version] ->
        if version in Server.protocol_versions(),
          do: conn,
          else:
            conn
            |> error(400, :invalid_request, "Unsupported MCP-Protocol-Version: #{version}")
            |> halt()

      _ ->
        conn |> error(400, :invalid_request, "Multiple MCP-Protocol-Version headers") |> halt()
    end
  end

  defp error(conn, status, code, message) do
    conn
    |> put_status(status)
    |> json(JsonRpc.error(nil, code, message))
  end
end
