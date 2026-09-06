defmodule ResidencySchedule.OAuth do
  @moduledoc """
  OAuth 2.1 authorization server backing the MCP endpoint: dynamic client
  registration, authorization codes with PKCE, access/refresh token issuance
  with rotation, and bearer token verification bound to the MCP resource.

  Every public function that can fail returns `{:error, reason}` where
  `reason` is an OAuth error code atom (`:invalid_grant`, `:invalid_client`,
  `:invalid_request`, `:invalid_token`) suitable for the wire.
  """
  import Ecto.Query

  alias ResidencySchedule.Accounts.User
  alias ResidencySchedule.OAuth.{AuthorizationCode, Client, Metadata, PKCE, Secret, Token}
  alias ResidencySchedule.Repo

  # ── Clients ────────────────────────────────────────────────────────────────

  @doc """
  Registers a client from an RFC 7591 request body. Returns the client and,
  for confidential clients, the plaintext secret (nil for public clients).

  Exempt from doctest — writes to the database.
  """
  def register_client(attrs) when is_map(attrs) do
    method = Map.get(attrs, "token_endpoint_auth_method", "none")
    secret = if method == "none", do: nil, else: Secret.generate()

    %Client{}
    |> Client.changeset(%{
      client_id: Secret.generate(16),
      client_secret_hash: secret && Secret.hash(secret),
      client_name: Map.get(attrs, "client_name"),
      redirect_uris: Map.get(attrs, "redirect_uris", []),
      token_endpoint_auth_method: method
    })
    |> Repo.insert()
    |> case do
      {:ok, client} -> {:ok, client, secret}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Fetches a client by its public client_id, or nil.

  Exempt from doctest — reads the database.
  """
  def get_client(client_id) when is_binary(client_id),
    do: Repo.get_by(Client, client_id: client_id)

  def get_client(_client_id), do: nil

  @doc """
  Authenticates a client for the token endpoint. Public clients need only a
  known client_id; confidential clients must present their secret.

  Exempt from doctest — reads the database.
  """
  def authenticate_client(client_id, client_secret) do
    case get_client(client_id) do
      nil -> {:error, :invalid_client}
      client -> check_client_secret(client, client_secret)
    end
  end

  defp check_client_secret(%Client{token_endpoint_auth_method: "none"} = client, _secret),
    do: {:ok, client}

  defp check_client_secret(%Client{client_secret_hash: hash} = client, secret) do
    if Secret.matches?(secret, hash), do: {:ok, client}, else: {:error, :invalid_client}
  end

  @doc """
  Returns true when the redirect URI is exactly one of the client's registered URIs.

      iex> client = %ResidencySchedule.OAuth.Client{redirect_uris: ["https://a.example/cb"]}
      iex> ResidencySchedule.OAuth.registered_redirect_uri?(client, "https://a.example/cb")
      true

      iex> client = %ResidencySchedule.OAuth.Client{redirect_uris: ["https://a.example/cb"]}
      iex> ResidencySchedule.OAuth.registered_redirect_uri?(client, "https://a.example/other")
      false
  """
  def registered_redirect_uri?(%Client{redirect_uris: uris}, redirect_uri) do
    redirect_uri in uris
  end

  # ── Authorization codes ────────────────────────────────────────────────────

  @doc """
  Issues an authorization code for a user who approved the client. `params`
  carries the authorization request: `redirect_uri`, `code_challenge`,
  `code_challenge_method`, `scope`, `resource`. Returns the plaintext code.

  Exempt from doctest — writes to the database.
  """
  def create_authorization_code(%Client{} = client, %User{} = user, params) do
    code = Secret.generate()

    %AuthorizationCode{}
    |> AuthorizationCode.changeset(%{
      code_hash: Secret.hash(code),
      client_id: client.id,
      user_id: user.id,
      redirect_uri: params[:redirect_uri],
      code_challenge: params[:code_challenge],
      code_challenge_method: params[:code_challenge_method] || "S256",
      scope: params[:scope],
      resource: params[:resource],
      expires_at: expires_in(AuthorizationCode.validity_seconds())
    })
    |> Repo.insert()
    |> case do
      {:ok, _record} -> {:ok, code}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Exchanges an authorization code for tokens (`grant_type=authorization_code`).
  Verifies the client, the code's binding to that client and redirect URI, PKCE,
  expiry, single use, and that the requested `resource` is this server.

  Exempt from doctest — reads and writes the database.
  """
  def exchange_authorization_code(params, base_url) do
    with {:ok, client} <- authenticate_client(params["client_id"], params["client_secret"]),
         {:ok, code} <- fetch_unused_code(params["code"]),
         :ok <- ensure_code_belongs_to(code, client),
         :ok <- ensure_redirect_uri_matches(code, params["redirect_uri"]),
         :ok <- ensure_pkce(code, params["code_verifier"]),
         :ok <- ensure_resource(params["resource"], base_url),
         {:ok, _used} <- mark_code_used(code) do
      issue_tokens(client, code.user_id, code.scope, Metadata.resource_uri(base_url))
    end
  end

  @doc """
  Rotates a refresh token (`grant_type=refresh_token`): the presented token is
  revoked and a fresh access/refresh pair is issued for the same user, client,
  scope, and resource.

  Exempt from doctest — reads and writes the database.
  """
  def refresh_access_token(params, base_url) do
    with {:ok, client} <- authenticate_client(params["client_id"], params["client_secret"]),
         {:ok, token} <- fetch_live_refresh_token(params["refresh_token"]),
         :ok <- ensure_token_belongs_to(token, client),
         :ok <- ensure_resource(params["resource"], base_url),
         {:ok, _revoked} <- revoke(token) do
      issue_tokens(client, token.user_id, token.scope, token.resource)
    end
  end

  @doc """
  Verifies a bearer access token presented to the MCP endpoint. Succeeds only
  for an unexpired, unrevoked token issued for this server's MCP resource whose
  user is still approved.

  Exempt from doctest — reads the database.
  """
  def verify_access_token(access_token, base_url) when is_binary(access_token) do
    with {:ok, token} <- fetch_live_access_token(access_token),
         :ok <- ensure_audience(token, base_url),
         %User{approved: true} = user <- Repo.get(User, token.user_id) do
      {:ok, user}
    else
      _ -> {:error, :invalid_token}
    end
  end

  def verify_access_token(_access_token, _base_url), do: {:error, :invalid_token}

  @doc """
  Revokes a token record so neither its access nor refresh token can be used again.

  Exempt from doctest — writes to the database.
  """
  def revoke(%Token{} = token) do
    token
    |> Token.changeset(%{revoked_at: DateTime.utc_now(:second)})
    |> Repo.update()
  end

  @doc """
  Deletes expired authorization codes and expired or revoked tokens.

  Exempt from doctest — writes to the database.
  """
  def cleanup do
    now = DateTime.utc_now(:second)
    {codes, _} = Repo.delete_all(from(c in AuthorizationCode, where: c.expires_at < ^now))

    {tokens, _} =
      Repo.delete_all(from(t in Token, where: t.expires_at < ^now or not is_nil(t.revoked_at)))

    %{codes: codes, tokens: tokens}
  end

  # ── Private ────────────────────────────────────────────────────────────────

  defp fetch_unused_code(code) when is_binary(code) do
    case Repo.get_by(AuthorizationCode, code_hash: Secret.hash(code)) do
      %AuthorizationCode{used_at: nil} = record -> reject_if_expired(record, :invalid_grant)
      _ -> {:error, :invalid_grant}
    end
  end

  defp fetch_unused_code(_code), do: {:error, :invalid_grant}

  defp ensure_code_belongs_to(%AuthorizationCode{client_id: id}, %Client{id: id}), do: :ok
  defp ensure_code_belongs_to(_code, _client), do: {:error, :invalid_grant}

  defp ensure_redirect_uri_matches(%AuthorizationCode{redirect_uri: uri}, uri), do: :ok
  defp ensure_redirect_uri_matches(_code, _uri), do: {:error, :invalid_grant}

  defp ensure_pkce(%AuthorizationCode{} = code, verifier) do
    if PKCE.verify?(verifier, code.code_challenge, code.code_challenge_method),
      do: :ok,
      else: {:error, :invalid_grant}
  end

  # RFC 8707: clients MUST send `resource`; we tolerate its absence but reject
  # any value that does not name this MCP server.
  defp ensure_resource(nil, _base_url), do: :ok

  defp ensure_resource(resource, base_url) do
    if Metadata.resource_matches?(resource, base_url), do: :ok, else: {:error, :invalid_target}
  end

  defp mark_code_used(code) do
    code
    |> AuthorizationCode.changeset(%{used_at: DateTime.utc_now(:second)})
    |> Repo.update()
  end

  defp issue_tokens(%Client{} = client, user_id, scope, resource) do
    access = Secret.generate()
    refresh = Secret.generate()

    %Token{}
    |> Token.changeset(%{
      access_token_hash: Secret.hash(access),
      refresh_token_hash: Secret.hash(refresh),
      client_id: client.id,
      user_id: user_id,
      scope: scope,
      resource: resource,
      expires_at: expires_in(Token.access_validity_seconds())
    })
    |> Repo.insert()
    |> case do
      {:ok, _token} ->
        {:ok,
         %{
           access_token: access,
           token_type: "Bearer",
           expires_in: Token.access_validity_seconds(),
           refresh_token: refresh,
           scope: scope
         }}

      {:error, _changeset} ->
        {:error, :server_error}
    end
  end

  defp fetch_live_refresh_token(refresh) when is_binary(refresh) do
    case Repo.get_by(Token, refresh_token_hash: Secret.hash(refresh)) do
      %Token{revoked_at: nil} = token -> {:ok, token}
      _ -> {:error, :invalid_grant}
    end
  end

  defp fetch_live_refresh_token(_refresh), do: {:error, :invalid_grant}

  defp fetch_live_access_token(access) do
    case Repo.get_by(Token, access_token_hash: Secret.hash(access)) do
      %Token{revoked_at: nil} = token -> reject_if_expired(token, :invalid_token)
      _ -> {:error, :invalid_token}
    end
  end

  defp ensure_token_belongs_to(%Token{client_id: id}, %Client{id: id}), do: :ok
  defp ensure_token_belongs_to(_token, _client), do: {:error, :invalid_grant}

  defp ensure_audience(%Token{resource: resource}, base_url) do
    if Metadata.resource_matches?(resource, base_url), do: :ok, else: {:error, :invalid_token}
  end

  defp reject_if_expired(%{expires_at: expires_at} = record, error) do
    if DateTime.compare(expires_at, DateTime.utc_now(:second)) == :gt,
      do: {:ok, record},
      else: {:error, error}
  end

  defp expires_in(seconds) do
    DateTime.utc_now(:second) |> DateTime.add(seconds, :second)
  end
end
