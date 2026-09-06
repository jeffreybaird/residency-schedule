defmodule ResidencyScheduleWeb.OAuthControllerTest do
  use ResidencyScheduleWeb.ConnCase, async: true

  import ResidencySchedule.ScheduleFixtures

  alias ResidencySchedule.{Accounts, OAuth}
  alias ResidencySchedule.OAuth.PKCE

  @redirect "https://client.example/callback"
  @verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

  defp base, do: ResidencyScheduleWeb.Endpoint.url()
  defp resource, do: base() <> "/mcp"

  defp register(conn, extra \\ %{}) do
    body = Map.merge(%{"client_name" => "Claude", "redirect_uris" => [@redirect]}, extra)
    conn = post(conn, "/oauth/register", body)
    {json_response(conn, 201), conn}
  end

  defp authorize_params(client_id, extra \\ %{}) do
    Map.merge(
      %{
        "response_type" => "code",
        "client_id" => client_id,
        "redirect_uri" => @redirect,
        "code_challenge" => PKCE.challenge(@verifier),
        "code_challenge_method" => "S256",
        "state" => "xyz",
        "resource" => resource()
      },
      extra
    )
  end

  defp logged_in(conn, user), do: Plug.Test.init_test_session(conn, user_id: user.id)

  defp redirect_query(conn) do
    conn |> redirected_to(302) |> URI.parse() |> Map.get(:query) |> URI.decode_query()
  end

  describe "discovery" do
    test "authorization server metadata", %{conn: conn} do
      body = conn |> get("/.well-known/oauth-authorization-server") |> json_response(200)
      assert body["issuer"] == base()
      assert body["authorization_endpoint"] == base() <> "/oauth/authorize"
      assert body["code_challenge_methods_supported"] == ["S256"]
    end

    test "protected resource metadata at both paths", %{conn: conn} do
      body = conn |> get("/.well-known/oauth-protected-resource") |> json_response(200)
      assert body["resource"] == resource()
      assert body["authorization_servers"] == [base()]

      assert conn |> get("/.well-known/oauth-protected-resource/mcp") |> json_response(200) ==
               body
    end
  end

  describe "POST /oauth/register" do
    test "registers a public client", %{conn: conn} do
      {body, _} = register(conn)
      assert body["client_id"]
      assert body["token_endpoint_auth_method"] == "none"
      refute Map.has_key?(body, "client_secret")
      assert body["grant_types"] == ["authorization_code", "refresh_token"]
    end

    test "registers a confidential client with a secret", %{conn: conn} do
      {body, _} = register(conn, %{"token_endpoint_auth_method" => "client_secret_basic"})
      assert body["client_secret"]
      assert body["client_secret_expires_at"] == 0
    end

    test "rejects bad redirect uris and bad metadata", %{conn: conn} do
      assert %{"error" => "invalid_redirect_uri"} =
               conn
               |> post("/oauth/register", %{"redirect_uris" => ["http://evil.example/cb"]})
               |> json_response(400)

      assert %{"error" => "invalid_client_metadata"} =
               conn
               |> post("/oauth/register", %{
                 "redirect_uris" => [@redirect],
                 "token_endpoint_auth_method" => "magic"
               })
               |> json_response(400)
    end
  end

  describe "GET /oauth/authorize" do
    setup %{conn: conn} do
      {client, _} = register(conn)
      %{client_id: client["client_id"], user: admin_user()}
    end

    test "redirects anonymous visitors to login and returns them afterwards", %{
      conn: conn,
      client_id: client_id
    } do
      {:ok, user} =
        Accounts.create_user(%{
          email: "pw-#{System.unique_integer([:positive])}@urmc.rochester.edu"
        })

      {:ok, user} = Accounts.set_password(user, "hunter2hunter2")

      conn = get(conn, "/oauth/authorize", authorize_params(client_id))
      assert redirected_to(conn) == "/login"
      assert get_session(conn, :return_to) =~ "/oauth/authorize?"

      conn = post(conn, "/login/identify", %{"email" => user.email})
      conn = post(conn, "/login/password", %{"password" => "hunter2hunter2"})
      assert redirected_to(conn) =~ "/oauth/authorize?"
      assert get_session(conn, :return_to) == nil
    end

    test "renders the consent page for a logged-in user", %{
      conn: conn,
      client_id: client_id,
      user: user
    } do
      html =
        conn
        |> logged_in(user)
        |> get("/oauth/authorize", authorize_params(client_id))
        |> html_response(200)

      assert html =~ "Claude"
      assert html =~ user.email
      assert html =~ ~s(name="code_challenge")
      assert html =~ "Approve or deny"
    end

    test "unknown client and unregistered redirect render errors without redirecting", %{
      conn: conn,
      client_id: client_id,
      user: user
    } do
      conn = logged_in(conn, user)

      assert conn |> get("/oauth/authorize", authorize_params("ghost")) |> html_response(400) =~
               "Unknown client"

      assert conn
             |> get(
               "/oauth/authorize",
               authorize_params(client_id, %{"redirect_uri" => "https://client.example/x"})
             )
             |> html_response(400) =~ "Invalid redirect URI"
    end

    test "missing redirect_uri falls back to the single registered one", %{
      conn: conn,
      client_id: client_id,
      user: user
    } do
      params = authorize_params(client_id) |> Map.delete("redirect_uri")

      assert conn |> logged_in(user) |> get("/oauth/authorize", params) |> html_response(200) =~
               "Allow access"
    end

    test "request errors redirect back with the state", %{
      conn: conn,
      client_id: client_id,
      user: user
    } do
      conn = logged_in(conn, user)

      q =
        conn
        |> get("/oauth/authorize", authorize_params(client_id, %{"code_challenge" => ""}))
        |> redirect_query()

      assert %{"error" => "invalid_request", "state" => "xyz"} = q

      q =
        conn
        |> get(
          "/oauth/authorize",
          authorize_params(client_id, %{"code_challenge_method" => "plain"})
        )
        |> redirect_query()

      assert q["error"] == "invalid_request"

      q =
        conn
        |> get("/oauth/authorize", authorize_params(client_id, %{"response_type" => "token"}))
        |> redirect_query()

      assert q["error"] == "unsupported_response_type"

      q =
        conn
        |> get(
          "/oauth/authorize",
          authorize_params(client_id, %{"resource" => "https://other.example/mcp"})
        )
        |> redirect_query()

      assert q["error"] == "invalid_target"
    end
  end

  describe "POST /oauth/authorize" do
    setup %{conn: conn} do
      {client, _} = register(conn)
      %{client_id: client["client_id"], user: admin_user()}
    end

    test "approve issues a code that the token endpoint accepts", %{
      conn: conn,
      client_id: client_id,
      user: user
    } do
      conn =
        conn
        |> logged_in(user)
        |> post("/oauth/authorize", authorize_params(client_id, %{"decision" => "approve"}))

      assert %{"code" => code, "state" => "xyz"} = redirect_query(conn)

      tokens =
        build_conn()
        |> post("/oauth/token", %{
          "grant_type" => "authorization_code",
          "client_id" => client_id,
          "code" => code,
          "redirect_uri" => @redirect,
          "code_verifier" => @verifier,
          "resource" => resource()
        })
        |> json_response(200)

      assert tokens["token_type"] == "Bearer"
      assert {:ok, %{id: id}} = OAuth.verify_access_token(tokens["access_token"], base())
      assert id == user.id
    end

    test "deny redirects with access_denied", %{conn: conn, client_id: client_id, user: user} do
      conn =
        conn
        |> logged_in(user)
        |> post("/oauth/authorize", authorize_params(client_id, %{"decision" => "deny"}))

      assert %{"error" => "access_denied", "state" => "xyz"} = redirect_query(conn)
    end

    test "anonymous decision goes to login", %{conn: conn, client_id: client_id} do
      conn =
        post(conn, "/oauth/authorize", authorize_params(client_id, %{"decision" => "approve"}))

      assert redirected_to(conn) == "/login"
    end

    test "tampered hidden fields are re-validated", %{
      conn: conn,
      client_id: client_id,
      user: user
    } do
      conn = logged_in(conn, user)

      assert conn
             |> post("/oauth/authorize", authorize_params("ghost", %{"decision" => "approve"}))
             |> html_response(400)

      assert conn
             |> post(
               "/oauth/authorize",
               authorize_params(client_id, %{
                 "decision" => "approve",
                 "redirect_uri" => "https://evil.example/"
               })
             )
             |> html_response(400) =~ "Invalid redirect URI"

      q =
        conn
        |> post(
          "/oauth/authorize",
          authorize_params(client_id, %{"decision" => "approve", "code_challenge" => ""})
        )
        |> redirect_query()

      assert q["error"] == "invalid_request"
    end
  end

  describe "POST /oauth/token" do
    setup %{conn: conn} do
      {client, _} = register(conn, %{"token_endpoint_auth_method" => "client_secret_basic"})
      user = admin_user()
      {:ok, db_client, _} = {:ok, OAuth.get_client(client["client_id"]), nil}

      {:ok, code} =
        OAuth.create_authorization_code(db_client, user, %{
          redirect_uri: @redirect,
          code_challenge: PKCE.challenge(@verifier),
          resource: resource()
        })

      %{client: client, code: code}
    end

    test "basic auth for confidential clients and refresh rotation", %{
      conn: conn,
      client: client,
      code: code
    } do
      basic = Base.encode64(client["client_id"] <> ":" <> client["client_secret"])

      tokens =
        conn
        |> put_req_header("authorization", "Basic " <> basic)
        |> post("/oauth/token", %{
          "grant_type" => "authorization_code",
          "code" => code,
          "redirect_uri" => @redirect,
          "code_verifier" => @verifier
        })
        |> json_response(200)

      assert ["no-store"] =
               conn
               |> put_req_header("authorization", "Basic " <> basic)
               |> post("/oauth/token", %{
                 "grant_type" => "refresh_token",
                 "refresh_token" => tokens["refresh_token"]
               })
               |> get_resp_header("cache-control")

      refreshed =
        build_conn()
        |> put_req_header("authorization", "Basic " <> basic)
        |> post("/oauth/token", %{
          "grant_type" => "refresh_token",
          "refresh_token" => tokens["refresh_token"]
        })
        |> json_response(400)

      assert refreshed["error"] == "invalid_grant"
    end

    test "wrong secret is 401 invalid_client", %{conn: conn, client: client, code: code} do
      body =
        conn
        |> post("/oauth/token", %{
          "grant_type" => "authorization_code",
          "client_id" => client["client_id"],
          "client_secret" => "bad",
          "code" => code,
          "redirect_uri" => @redirect,
          "code_verifier" => @verifier
        })
        |> json_response(401)

      assert body["error"] == "invalid_client"
    end

    test "unsupported grant type and invalid grant", %{conn: conn, client: client} do
      assert %{"error" => "unsupported_grant_type"} =
               conn |> post("/oauth/token", %{"grant_type" => "password"}) |> json_response(400)

      basic = Base.encode64(client["client_id"] <> ":" <> client["client_secret"])

      assert %{"error" => "invalid_grant"} =
               conn
               |> put_req_header("authorization", "Basic " <> basic)
               |> post("/oauth/token", %{
                 "grant_type" => "authorization_code",
                 "code" => "nope",
                 "redirect_uri" => @redirect,
                 "code_verifier" => @verifier
               })
               |> json_response(400)
    end

    test "malformed basic header falls through to body credentials", %{conn: conn} do
      assert %{"error" => "invalid_client"} =
               conn
               |> put_req_header("authorization", "Basic !!!")
               |> post("/oauth/token", %{"grant_type" => "authorization_code", "code" => "x"})
               |> json_response(401)
    end
  end
end
