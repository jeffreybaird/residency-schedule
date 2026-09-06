defmodule ResidencyScheduleWeb.OAuthController do
  @moduledoc """
  OAuth 2.1 authorization server endpoints for MCP clients: discovery
  metadata, dynamic client registration, the browser consent flow, and the
  token endpoint. The consent flow reuses the app's session login: an
  unauthenticated user is sent to /login and returned here afterwards.
  """
  use ResidencyScheduleWeb, :controller

  alias ResidencySchedule.{Accounts, OAuth}
  alias ResidencySchedule.Accounts.User
  alias ResidencySchedule.OAuth.{Client, Metadata}

  @authorize_fields ~w(client_id redirect_uri state scope resource code_challenge code_challenge_method)

  # ── Discovery ──────────────────────────────────────────────────────────────

  @doc """
  RFC 8414 authorization server metadata.

  Exempt from doctest — controller action.
  """
  def authorization_server_metadata(conn, _params) do
    json(conn, Metadata.authorization_server(base_url()))
  end

  @doc """
  RFC 9728 protected resource metadata for the MCP endpoint.

  Exempt from doctest — controller action.
  """
  def protected_resource_metadata(conn, _params) do
    json(conn, Metadata.protected_resource(base_url()))
  end

  # ── Dynamic client registration ────────────────────────────────────────────

  @doc """
  RFC 7591 registration. Accepts `client_name`, `redirect_uris`, and
  `token_endpoint_auth_method`; other metadata is ignored.

  Exempt from doctest — controller action.
  """
  def register(conn, params) do
    case OAuth.register_client(params) do
      {:ok, client, secret} ->
        conn |> put_status(201) |> json(registration_response(client, secret))

      {:error, changeset} ->
        conn
        |> put_status(400)
        |> json(%{
          error: registration_error(changeset),
          error_description: "Invalid client metadata"
        })
    end
  end

  # ── Authorization (browser) ────────────────────────────────────────────────

  @doc """
  Shows the consent page for a valid authorization request, or sends the
  visitor to log in first.

  Exempt from doctest — controller action.
  """
  def authorize(conn, params) do
    with {:ok, client, redirect_uri} <- validate_client_and_redirect(params),
         :ok <- validate_authorization_request(client, redirect_uri, params) do
      case current_user(conn) do
        %User{} = user ->
          render(conn, :authorize,
            user: user,
            client: client,
            request: Map.take(params, @authorize_fields)
          )

        nil ->
          conn
          |> put_session(:return_to, current_path(conn))
          |> redirect(to: "/login")
      end
    else
      {:error, :invalid_client} ->
        error_page(conn, "Unknown client", "This application is not registered.")

      {:error, :invalid_redirect_uri} ->
        error_page(
          conn,
          "Invalid redirect URI",
          "The redirect URI is not registered for this application."
        )

      {:error, redirect_uri, error, description, state} ->
        redirect(conn,
          external:
            append_query(redirect_uri, error: error, error_description: description, state: state)
        )
    end
  end

  @doc """
  Handles the consent decision. Approving issues an authorization code and
  redirects back to the client; denying redirects with `access_denied`.

  Exempt from doctest — controller action.
  """
  def decide(conn, params) do
    with %User{} = user <- current_user(conn),
         {:ok, client, redirect_uri} <- validate_client_and_redirect(params),
         :ok <- validate_authorization_request(client, redirect_uri, params) do
      finish_decision(conn, user, client, redirect_uri, params)
    else
      nil ->
        redirect(conn, to: "/login")

      {:error, :invalid_client} ->
        error_page(conn, "Unknown client", "This application is not registered.")

      {:error, :invalid_redirect_uri} ->
        error_page(conn, "Invalid redirect URI", "The redirect URI is not registered.")

      {:error, redirect_uri, error, description, state} ->
        redirect(conn,
          external:
            append_query(redirect_uri, error: error, error_description: description, state: state)
        )
    end
  end

  # ── Token ──────────────────────────────────────────────────────────────────

  @doc """
  Token endpoint: `authorization_code` and `refresh_token` grants. Client
  credentials may arrive in the body or as HTTP Basic.

  Exempt from doctest — controller action.
  """
  def token(conn, params) do
    params = merge_basic_auth(conn, params)

    result =
      case params["grant_type"] do
        "authorization_code" -> OAuth.exchange_authorization_code(params, base_url())
        "refresh_token" -> OAuth.refresh_access_token(params, base_url())
        _ -> {:error, :unsupported_grant_type}
      end

    conn = put_resp_header(conn, "cache-control", "no-store")

    case result do
      {:ok, tokens} -> json(conn, tokens)
      {:error, :invalid_client} -> token_error(conn, 401, :invalid_client)
      {:error, reason} when is_atom(reason) -> token_error(conn, 400, reason)
    end
  end

  # ── Private: authorization validation ──────────────────────────────────────

  defp validate_client_and_redirect(params) do
    with %Client{} = client <- OAuth.get_client(params["client_id"]) || {:error, :invalid_client},
         {:ok, redirect_uri} <- pick_redirect_uri(client, params["redirect_uri"]) do
      {:ok, client, redirect_uri}
    end
  end

  defp pick_redirect_uri(%Client{redirect_uris: [only]}, nil), do: {:ok, only}

  defp pick_redirect_uri(client, uri) do
    if is_binary(uri) and OAuth.registered_redirect_uri?(client, uri),
      do: {:ok, uri},
      else: {:error, :invalid_redirect_uri}
  end

  defp validate_authorization_request(_client, redirect_uri, params) do
    state = params["state"]

    cond do
      params["response_type"] != "code" and params["response_type"] != nil ->
        {:error, redirect_uri, "unsupported_response_type",
         "Only response_type=code is supported", state}

      not is_binary(params["code_challenge"]) or params["code_challenge"] == "" ->
        {:error, redirect_uri, "invalid_request", "code_challenge is required (PKCE)", state}

      params["code_challenge_method"] not in ["S256", nil] ->
        {:error, redirect_uri, "invalid_request", "Only code_challenge_method=S256 is supported",
         state}

      is_binary(params["resource"]) and
          not Metadata.resource_matches?(params["resource"], base_url()) ->
        {:error, redirect_uri, "invalid_target",
         "resource must be #{Metadata.resource_uri(base_url())}", state}

      true ->
        :ok
    end
  end

  defp finish_decision(conn, user, client, redirect_uri, %{"decision" => "approve"} = params) do
    {:ok, code} =
      OAuth.create_authorization_code(client, user, %{
        redirect_uri: redirect_uri,
        code_challenge: params["code_challenge"],
        code_challenge_method: params["code_challenge_method"] || "S256",
        scope: params["scope"],
        resource: params["resource"]
      })

    redirect(conn, external: append_query(redirect_uri, code: code, state: params["state"]))
  end

  defp finish_decision(conn, _user, _client, redirect_uri, params) do
    redirect(conn,
      external:
        append_query(redirect_uri,
          error: "access_denied",
          error_description: "The user declined",
          state: params["state"]
        )
    )
  end

  # ── Private: helpers ───────────────────────────────────────────────────────

  defp current_user(conn) do
    with id when not is_nil(id) <- get_session(conn, :user_id),
         %User{approved: true} = user <- Accounts.get_user(id) do
      user
    else
      _ -> nil
    end
  end

  defp merge_basic_auth(conn, params) do
    with ["Basic " <> encoded] <- get_req_header(conn, "authorization"),
         {:ok, decoded} <- Base.decode64(encoded),
         [id, secret] <- String.split(decoded, ":", parts: 2) do
      Map.merge(params, %{
        "client_id" => URI.decode_www_form(id),
        "client_secret" => URI.decode_www_form(secret)
      })
    else
      _ -> params
    end
  end

  defp token_error(conn, status, reason) do
    conn
    |> put_status(status)
    |> json(%{error: Atom.to_string(reason), error_description: token_error_description(reason)})
  end

  defp token_error_description(:invalid_client), do: "Client authentication failed"

  defp token_error_description(:invalid_grant),
    do: "The code or refresh token is invalid, expired, or already used"

  defp token_error_description(:invalid_target), do: "The resource is not this server"

  defp token_error_description(:unsupported_grant_type),
    do: "grant_type must be authorization_code or refresh_token"

  defp token_error_description(_reason), do: "The request could not be processed"

  defp registration_response(client, secret) do
    %{
      client_id: client.client_id,
      client_name: client.client_name,
      redirect_uris: client.redirect_uris,
      token_endpoint_auth_method: client.token_endpoint_auth_method,
      grant_types: ["authorization_code", "refresh_token"],
      response_types: ["code"],
      client_id_issued_at: DateTime.to_unix(client.inserted_at)
    }
    |> maybe_put_secret(secret)
  end

  defp maybe_put_secret(response, nil), do: response

  defp maybe_put_secret(response, secret),
    do: Map.merge(response, %{client_secret: secret, client_secret_expires_at: 0})

  defp registration_error(%Ecto.Changeset{errors: errors}) do
    if Keyword.has_key?(errors, :redirect_uris),
      do: "invalid_redirect_uri",
      else: "invalid_client_metadata"
  end

  defp error_page(conn, title, message) do
    conn
    |> put_status(400)
    |> render(:error, title: title, message: message)
  end

  defp append_query(uri, pairs) do
    query = pairs |> Enum.reject(fn {_k, v} -> is_nil(v) end) |> URI.encode_query()
    parsed = URI.parse(uri)
    existing = parsed.query

    %URI{parsed | query: if(existing in [nil, ""], do: query, else: existing <> "&" <> query)}
    |> URI.to_string()
  end

  defp base_url, do: ResidencyScheduleWeb.Endpoint.url()
end
