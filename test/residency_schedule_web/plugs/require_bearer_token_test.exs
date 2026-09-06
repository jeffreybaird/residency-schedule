defmodule ResidencyScheduleWeb.Plugs.RequireBearerTokenTest do
  use ResidencyScheduleWeb.ConnCase, async: true

  import ResidencySchedule.ScheduleFixtures

  alias ResidencySchedule.OAuth
  alias ResidencySchedule.OAuth.PKCE
  alias ResidencyScheduleWeb.Plugs.RequireBearerToken

  doctest RequireBearerToken

  defp issue_token(user) do
    base = ResidencyScheduleWeb.Endpoint.url()
    {:ok, client, nil} = OAuth.register_client(%{"redirect_uris" => ["https://c.example/cb"]})

    {:ok, code} =
      OAuth.create_authorization_code(client, user, %{
        redirect_uri: "https://c.example/cb",
        code_challenge: PKCE.challenge("verifier-verifier-verifier-verifier-verifier"),
        resource: base <> "/mcp"
      })

    {:ok, tokens} =
      OAuth.exchange_authorization_code(
        %{
          "client_id" => client.client_id,
          "code" => code,
          "redirect_uri" => "https://c.example/cb",
          "code_verifier" => "verifier-verifier-verifier-verifier-verifier"
        },
        base
      )

    tokens.access_token
  end

  test "assigns the user for a valid token", %{conn: conn} do
    user = admin_user()
    token = issue_token(user)

    conn =
      conn
      |> put_req_header("authorization", "Bearer " <> token)
      |> RequireBearerToken.call([])

    refute conn.halted
    assert conn.assigns.current_user.id == user.id
  end

  test "401 with resource metadata challenge when the token is missing", %{conn: conn} do
    conn = RequireBearerToken.call(conn, [])
    assert conn.halted
    assert conn.status == 401
    [challenge] = get_resp_header(conn, "www-authenticate")
    base = ResidencyScheduleWeb.Endpoint.url()
    assert challenge =~ ~s(resource_metadata="#{base}/.well-known/oauth-protected-resource")
    assert Jason.decode!(conn.resp_body)["error"] == "invalid_token"
  end

  test "401 for a bogus token and a non-bearer scheme", %{conn: conn} do
    assert %{status: 401} =
             conn |> put_req_header("authorization", "Bearer nope") |> RequireBearerToken.call([])

    assert %{status: 401} =
             conn |> put_req_header("authorization", "Basic abc") |> RequireBearerToken.call([])

    assert %{status: 401} =
             conn |> put_req_header("authorization", "Bearer") |> RequireBearerToken.call([])
  end

  test "bearer_token/1 is case-insensitive on the scheme", %{conn: conn} do
    assert {:ok, "x"} =
             conn
             |> put_req_header("authorization", "bearer x")
             |> RequireBearerToken.bearer_token()
  end
end
