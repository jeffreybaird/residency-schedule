defmodule ResidencySchedule.OAuth.Metadata do
  @moduledoc """
  Builds the discovery documents MCP clients read: OAuth 2.0 Authorization
  Server Metadata (RFC 8414) and Protected Resource Metadata (RFC 9728).
  The app is both the authorization server and the resource server.
  """

  alias ResidencySchedule.OAuth.Client

  @mcp_path "/mcp"

  @doc """
  Canonical resource URI for the MCP endpoint (RFC 8707). Trailing slashes
  on the base URL are dropped.

      iex> ResidencySchedule.OAuth.Metadata.resource_uri("https://schedule.example")
      "https://schedule.example/mcp"

      iex> ResidencySchedule.OAuth.Metadata.resource_uri("https://schedule.example/")
      "https://schedule.example/mcp"
  """
  def resource_uri(base_url) when is_binary(base_url) do
    String.trim_trailing(base_url, "/") <> @mcp_path
  end

  @doc """
  Returns true when a client-supplied `resource` parameter names this server.
  Scheme and host compare case-insensitively; a trailing slash is ignored.

      iex> ResidencySchedule.OAuth.Metadata.resource_matches?("HTTPS://Schedule.example/mcp", "https://schedule.example")
      true

      iex> ResidencySchedule.OAuth.Metadata.resource_matches?("https://other.example/mcp", "https://schedule.example")
      false
  """
  def resource_matches?(resource, base_url) when is_binary(resource) do
    normalize_uri(resource) == normalize_uri(resource_uri(base_url))
  end

  def resource_matches?(_resource, _base_url), do: false

  @doc """
  Authorization server metadata document.

      iex> doc = ResidencySchedule.OAuth.Metadata.authorization_server("https://schedule.example")
      iex> doc.token_endpoint
      "https://schedule.example/oauth/token"
      iex> doc.code_challenge_methods_supported
      ["S256"]
  """
  def authorization_server(base_url) do
    base = String.trim_trailing(base_url, "/")

    %{
      issuer: base,
      authorization_endpoint: base <> "/oauth/authorize",
      token_endpoint: base <> "/oauth/token",
      registration_endpoint: base <> "/oauth/register",
      response_types_supported: ["code"],
      response_modes_supported: ["query"],
      grant_types_supported: ["authorization_code", "refresh_token"],
      code_challenge_methods_supported: ["S256"],
      token_endpoint_auth_methods_supported: Client.auth_methods()
    }
  end

  @doc """
  Protected resource metadata document for the MCP endpoint.

      iex> doc = ResidencySchedule.OAuth.Metadata.protected_resource("https://schedule.example")
      iex> doc.resource
      "https://schedule.example/mcp"
      iex> doc.authorization_servers
      ["https://schedule.example"]
  """
  def protected_resource(base_url) do
    base = String.trim_trailing(base_url, "/")

    %{
      resource: resource_uri(base),
      authorization_servers: [base],
      bearer_methods_supported: ["header"],
      resource_name: "Residency Schedule MCP"
    }
  end

  @doc """
  URL of the protected resource metadata document, advertised in the
  `WWW-Authenticate` header on 401 responses.

      iex> ResidencySchedule.OAuth.Metadata.protected_resource_url("https://schedule.example")
      "https://schedule.example/.well-known/oauth-protected-resource"
  """
  def protected_resource_url(base_url) do
    String.trim_trailing(base_url, "/") <> "/.well-known/oauth-protected-resource"
  end

  defp normalize_uri(uri) do
    parsed = URI.parse(uri)

    %URI{
      parsed
      | scheme: parsed.scheme && String.downcase(parsed.scheme),
        host: parsed.host && String.downcase(parsed.host),
        path: parsed.path && String.trim_trailing(parsed.path, "/")
    }
    |> URI.to_string()
  end
end
