defmodule ResidencyScheduleWeb.MCP.JsonRpc do
  @moduledoc """
  JSON-RPC 2.0 message classification and response building for the MCP
  endpoint. Pure functions over decoded maps.
  """

  @parse_error -32_700
  @invalid_request -32_600
  @method_not_found -32_601
  @invalid_params -32_602
  @internal_error -32_603

  @doc """
  Classifies a decoded JSON-RPC message.

      iex> ResidencyScheduleWeb.MCP.JsonRpc.classify(%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
      {:request, 1, "ping", %{}}

      iex> ResidencyScheduleWeb.MCP.JsonRpc.classify(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"})
      {:notification, "notifications/initialized", %{}}

      iex> ResidencyScheduleWeb.MCP.JsonRpc.classify(%{"jsonrpc" => "2.0", "id" => 1, "result" => %{}})
      :response

      iex> ResidencyScheduleWeb.MCP.JsonRpc.classify(%{"hello" => "world"})
      :invalid
  """
  def classify(%{"jsonrpc" => "2.0", "method" => method} = msg) when is_binary(method) do
    params = params_of(msg)

    case Map.fetch(msg, "id") do
      {:ok, id} when is_integer(id) or is_binary(id) -> {:request, id, method, params}
      :error -> {:notification, method, params}
      _ -> :invalid
    end
  end

  def classify(%{"jsonrpc" => "2.0", "id" => _id} = msg)
      when is_map_key(msg, "result") or is_map_key(msg, "error"),
      do: :response

  def classify(_msg), do: :invalid

  @doc """
  Builds a success response.

      iex> ResidencyScheduleWeb.MCP.JsonRpc.result(7, %{ok: true})
      %{jsonrpc: "2.0", id: 7, result: %{ok: true}}
  """
  def result(id, result), do: %{jsonrpc: "2.0", id: id, result: result}

  @doc """
  Builds an error response with a standard code.

      iex> ResidencyScheduleWeb.MCP.JsonRpc.error(7, :method_not_found, "Unknown method: nope")
      %{jsonrpc: "2.0", id: 7, error: %{code: -32_601, message: "Unknown method: nope"}}
  """
  def error(id, code, message) do
    %{jsonrpc: "2.0", id: id, error: %{code: code_for(code), message: message}}
  end

  @doc """
  Numeric code for a named JSON-RPC error.

      iex> ResidencyScheduleWeb.MCP.JsonRpc.code_for(:invalid_params)
      -32_602
  """
  def code_for(:parse_error), do: @parse_error
  def code_for(:invalid_request), do: @invalid_request
  def code_for(:method_not_found), do: @method_not_found
  def code_for(:invalid_params), do: @invalid_params
  def code_for(:internal_error), do: @internal_error

  defp params_of(%{"params" => params}) when is_map(params), do: params
  defp params_of(_msg), do: %{}
end
