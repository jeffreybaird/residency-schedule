defmodule ResidencyScheduleWeb.Plugs.RequireBearerToken do
  @moduledoc """
  Authenticates MCP requests with an OAuth bearer token issued by this app.
  On failure it replies 401 with the `WWW-Authenticate` header MCP clients
  use to discover the protected resource metadata (RFC 9728 §5.1).
  """

  import Plug.Conn

  alias ResidencySchedule.OAuth
  alias ResidencySchedule.OAuth.Metadata

  @doc """
  Plug options are passed through unchanged.

      iex> ResidencyScheduleWeb.Plugs.RequireBearerToken.init([])
      []
  """
  def init(opts), do: opts

  @doc """
  Verifies the bearer token and assigns `:current_user`, or halts with 401.

  Exempt from doctest — verifies the token against the database.
  """
  def call(conn, _opts) do
    base_url = ResidencyScheduleWeb.Endpoint.url()

    with {:ok, token} <- bearer_token(conn),
         {:ok, user} <- OAuth.verify_access_token(token, base_url) do
      assign(conn, :current_user, user)
    else
      _ -> unauthorized(conn, base_url)
    end
  end

  @doc """
  Extracts the bearer token from the Authorization header.

      iex> conn = Plug.Test.conn(:post, "/mcp") |> Plug.Conn.put_req_header("authorization", "Bearer abc123")
      iex> ResidencyScheduleWeb.Plugs.RequireBearerToken.bearer_token(conn)
      {:ok, "abc123"}

      iex> ResidencyScheduleWeb.Plugs.RequireBearerToken.bearer_token(Plug.Test.conn(:post, "/mcp"))
      {:error, :missing_token}
  """
  def bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      [header] -> parse_bearer(header)
      _ -> {:error, :missing_token}
    end
  end

  defp parse_bearer(header) do
    case String.split(header, " ", parts: 2) do
      [scheme, token] when byte_size(token) > 0 ->
        if String.downcase(scheme) == "bearer",
          do: {:ok, String.trim(token)},
          else: {:error, :missing_token}

      _ ->
        {:error, :missing_token}
    end
  end

  defp unauthorized(conn, base_url) do
    challenge =
      ~s(Bearer resource_metadata="#{Metadata.protected_resource_url(base_url)}", error="invalid_token")

    conn
    |> put_resp_header("www-authenticate", challenge)
    |> put_resp_content_type("application/json")
    |> send_resp(
      401,
      Jason.encode!(%{
        error: "invalid_token",
        error_description: "A valid bearer token is required"
      })
    )
    |> halt()
  end
end
