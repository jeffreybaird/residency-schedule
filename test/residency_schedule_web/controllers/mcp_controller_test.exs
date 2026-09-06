defmodule ResidencyScheduleWeb.MCPControllerTest do
  use ResidencyScheduleWeb.ConnCase, async: true

  import ResidencySchedule.ScheduleFixtures

  alias ResidencySchedule.OAuth.PKCE

  @redirect "https://client.example/callback"
  @verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

  # Full client flow: discover -> register -> authorize -> token.
  defp obtain_token(conn, user) do
    prm = conn |> get("/.well-known/oauth-protected-resource") |> json_response(200)
    [as] = prm["authorization_servers"]
    assert as == ResidencyScheduleWeb.Endpoint.url()
    meta = conn |> get("/.well-known/oauth-authorization-server") |> json_response(200)

    client =
      conn
      |> post(URI.parse(meta["registration_endpoint"]).path, %{
        "client_name" => "Test",
        "redirect_uris" => [@redirect]
      })
      |> json_response(201)

    approve =
      conn
      |> Plug.Test.init_test_session(user_id: user.id)
      |> post(URI.parse(meta["authorization_endpoint"]).path, %{
        "client_id" => client["client_id"],
        "redirect_uri" => @redirect,
        "code_challenge" => PKCE.challenge(@verifier),
        "code_challenge_method" => "S256",
        "resource" => prm["resource"],
        "decision" => "approve"
      })

    %{"code" => code} =
      approve |> redirected_to() |> URI.parse() |> Map.get(:query) |> URI.decode_query()

    build_conn()
    |> post(URI.parse(meta["token_endpoint"]).path, %{
      "grant_type" => "authorization_code",
      "client_id" => client["client_id"],
      "code" => code,
      "redirect_uri" => @redirect,
      "code_verifier" => @verifier,
      "resource" => prm["resource"]
    })
    |> json_response(200)
    |> Map.fetch!("access_token")
  end

  defp rpc(conn, token, body) do
    conn
    |> put_req_header("authorization", "Bearer " <> token)
    |> put_req_header("accept", "application/json, text/event-stream")
    |> put_req_header("mcp-protocol-version", "2025-06-18")
    |> post("/mcp", body)
  end

  setup %{conn: conn} do
    fixtures = seed_mini_schedule()
    user = resident_user(fixtures.clare)
    %{token: obtain_token(conn, user), user: user}
  end

  test "initialize, tools/list, tools/call over HTTP", %{conn: conn, token: token} do
    init =
      rpc(conn, token, %{
        "jsonrpc" => "2.0",
        "id" => 1,
        "method" => "initialize",
        "params" => %{"protocolVersion" => "2025-06-18"}
      })
      |> json_response(200)

    assert init["result"]["protocolVersion"] == "2025-06-18"

    assert rpc(conn, token, %{"jsonrpc" => "2.0", "method" => "notifications/initialized"}).status ==
             202

    tools =
      rpc(conn, token, %{"jsonrpc" => "2.0", "id" => 2, "method" => "tools/list"})
      |> json_response(200)

    assert Enum.any?(tools["result"]["tools"], &(&1["name"] == "shared_shifts"))

    call =
      rpc(conn, token, %{
        "jsonrpc" => "2.0",
        "id" => 3,
        "method" => "tools/call",
        "params" => %{
          "name" => "shared_shifts",
          "arguments" => %{"resident" => "clare", "coworker" => "mary", "from" => "2026-07-06"}
        }
      })
      |> json_response(200)

    assert call["result"]["structuredContent"]["count"] == 7
    assert call["result"]["isError"] == false
  end

  test "requires a bearer token", %{conn: conn} do
    conn = post(conn, "/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})
    assert conn.status == 401
    assert [challenge] = get_resp_header(conn, "www-authenticate")
    assert challenge =~ "resource_metadata="
  end

  test "rejects batches, bad versions, foreign origins, and garbage", %{conn: conn, token: token} do
    batch =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("content-type", "application/json")
      |> post("/mcp", Jason.encode!([%{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"}]))

    assert json_response(batch, 400)["error"]["code"] == -32_600

    bad_version =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> put_req_header("mcp-protocol-version", "1999-01-01")
      |> post("/mcp", %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

    assert json_response(bad_version, 400)["error"]["message"] =~ "Unsupported"

    foreign =
      conn
      |> put_req_header("origin", "https://evil.example")
      |> rpc(token, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

    assert foreign.status == 403

    same =
      conn
      |> put_req_header("origin", "http://www.example.com")
      |> rpc(token, %{"jsonrpc" => "2.0", "id" => 1, "method" => "ping"})

    assert json_response(same, 200)["result"] == %{}

    assert rpc(conn, token, %{"nope" => true}) |> json_response(400) |> get_in(["error", "code"]) ==
             -32_600
  end

  test "GET and DELETE are 405", %{conn: conn, token: token} do
    get_conn = conn |> put_req_header("authorization", "Bearer " <> token) |> get("/mcp")
    assert get_conn.status == 405
    assert ["POST"] = get_resp_header(get_conn, "allow")

    assert (conn |> put_req_header("authorization", "Bearer " <> token) |> delete("/mcp")).status ==
             405
  end
end
