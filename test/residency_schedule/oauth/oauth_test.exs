defmodule ResidencySchedule.OAuthTest do
  use ResidencySchedule.DataCase, async: true

  alias ResidencySchedule.{Accounts, OAuth}
  alias ResidencySchedule.OAuth.{AuthorizationCode, PKCE, Secret, Token}

  @base "https://schedule.example"
  @redirect "https://client.example/callback"
  @verifier "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"

  setup do
    {:ok, user} =
      Accounts.create_user(%{email: "res-#{System.unique_integer()}@urmc.rochester.edu"})

    {:ok, client, nil} =
      OAuth.register_client(%{"client_name" => "Test", "redirect_uris" => [@redirect]})

    %{user: user, client: client}
  end

  defp issue_code(client, user, overrides \\ %{}) do
    params =
      Map.merge(
        %{
          redirect_uri: @redirect,
          code_challenge: PKCE.challenge(@verifier),
          code_challenge_method: "S256",
          scope: "schedule",
          resource: @base <> "/mcp"
        },
        overrides
      )

    {:ok, code} = OAuth.create_authorization_code(client, user, params)
    code
  end

  defp exchange_params(client, code, overrides \\ %{}) do
    Map.merge(
      %{
        "client_id" => client.client_id,
        "code" => code,
        "redirect_uri" => @redirect,
        "code_verifier" => @verifier,
        "resource" => @base <> "/mcp"
      },
      overrides
    )
  end

  describe "register_client/1" do
    test "public client gets no secret", %{client: client} do
      assert client.token_endpoint_auth_method == "none"
      assert client.client_secret_hash == nil
    end

    test "confidential client gets a secret that authenticates" do
      {:ok, client, secret} =
        OAuth.register_client(%{
          "redirect_uris" => [@redirect],
          "token_endpoint_auth_method" => "client_secret_post"
        })

      assert is_binary(secret)
      assert {:ok, _} = OAuth.authenticate_client(client.client_id, secret)
      assert {:error, :invalid_client} = OAuth.authenticate_client(client.client_id, "wrong")
    end

    test "rejects invalid redirect uris" do
      assert {:error, %Ecto.Changeset{}} =
               OAuth.register_client(%{"redirect_uris" => ["http://evil.example/cb"]})
    end
  end

  describe "get_client/1 and authenticate_client/2" do
    test "unknown client id" do
      assert OAuth.get_client("nope") == nil
      assert OAuth.get_client(nil) == nil
      assert {:error, :invalid_client} = OAuth.authenticate_client("nope", nil)
    end
  end

  describe "exchange_authorization_code/2" do
    test "happy path issues a bearer token bound to the resource", %{client: client, user: user} do
      code = issue_code(client, user)

      assert {:ok, tokens} =
               OAuth.exchange_authorization_code(exchange_params(client, code), @base)

      assert tokens.token_type == "Bearer"
      assert tokens.expires_in == Token.access_validity_seconds()
      assert {:ok, verified} = OAuth.verify_access_token(tokens.access_token, @base)
      assert verified.id == user.id
    end

    test "code is single use", %{client: client, user: user} do
      code = issue_code(client, user)
      assert {:ok, _} = OAuth.exchange_authorization_code(exchange_params(client, code), @base)

      assert {:error, :invalid_grant} =
               OAuth.exchange_authorization_code(exchange_params(client, code), @base)
    end

    test "rejects a wrong verifier", %{client: client, user: user} do
      code = issue_code(client, user)
      params = exchange_params(client, code, %{"code_verifier" => "wrong"})
      assert {:error, :invalid_grant} = OAuth.exchange_authorization_code(params, @base)
    end

    test "rejects a mismatched redirect uri", %{client: client, user: user} do
      code = issue_code(client, user)
      params = exchange_params(client, code, %{"redirect_uri" => "https://client.example/other"})
      assert {:error, :invalid_grant} = OAuth.exchange_authorization_code(params, @base)
    end

    test "rejects a code issued to another client", %{client: client, user: user} do
      {:ok, other, nil} = OAuth.register_client(%{"redirect_uris" => [@redirect]})
      code = issue_code(client, user)

      assert {:error, :invalid_grant} =
               OAuth.exchange_authorization_code(exchange_params(other, code), @base)
    end

    test "rejects an expired code", %{client: client, user: user} do
      code = issue_code(client, user)

      Repo.update_all(AuthorizationCode,
        set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second)]
      )

      assert {:error, :invalid_grant} =
               OAuth.exchange_authorization_code(exchange_params(client, code), @base)
    end

    test "rejects a foreign resource", %{client: client, user: user} do
      code = issue_code(client, user)
      params = exchange_params(client, code, %{"resource" => "https://other.example/mcp"})
      assert {:error, :invalid_target} = OAuth.exchange_authorization_code(params, @base)
    end

    test "tolerates a missing resource parameter", %{client: client, user: user} do
      code = issue_code(client, user)
      params = Map.delete(exchange_params(client, code), "resource")
      assert {:ok, _} = OAuth.exchange_authorization_code(params, @base)
    end

    test "rejects an unknown code and a nil code", %{client: client} do
      assert {:error, :invalid_grant} =
               OAuth.exchange_authorization_code(exchange_params(client, "zzz"), @base)

      assert {:error, :invalid_grant} =
               OAuth.exchange_authorization_code(exchange_params(client, nil), @base)
    end

    test "rejects an unknown client", %{client: client, user: user} do
      code = issue_code(client, user)
      params = exchange_params(client, code, %{"client_id" => "ghost"})
      assert {:error, :invalid_client} = OAuth.exchange_authorization_code(params, @base)
    end
  end

  describe "refresh_access_token/2" do
    test "rotates the refresh token and revokes the old pair", %{client: client, user: user} do
      code = issue_code(client, user)
      {:ok, first} = OAuth.exchange_authorization_code(exchange_params(client, code), @base)

      params = %{"client_id" => client.client_id, "refresh_token" => first.refresh_token}
      assert {:ok, second} = OAuth.refresh_access_token(params, @base)
      assert second.access_token != first.access_token
      assert second.scope == "schedule"

      assert {:error, :invalid_token} = OAuth.verify_access_token(first.access_token, @base)
      assert {:ok, _} = OAuth.verify_access_token(second.access_token, @base)
      assert {:error, :invalid_grant} = OAuth.refresh_access_token(params, @base)
    end

    test "rejects a refresh token from another client", %{client: client, user: user} do
      {:ok, other, nil} = OAuth.register_client(%{"redirect_uris" => [@redirect]})
      code = issue_code(client, user)
      {:ok, first} = OAuth.exchange_authorization_code(exchange_params(client, code), @base)

      params = %{"client_id" => other.client_id, "refresh_token" => first.refresh_token}
      assert {:error, :invalid_grant} = OAuth.refresh_access_token(params, @base)
    end

    test "rejects a foreign resource", %{client: client, user: user} do
      code = issue_code(client, user)
      {:ok, first} = OAuth.exchange_authorization_code(exchange_params(client, code), @base)

      params = %{
        "client_id" => client.client_id,
        "refresh_token" => first.refresh_token,
        "resource" => "https://other.example/mcp"
      }

      assert {:error, :invalid_target} = OAuth.refresh_access_token(params, @base)
    end

    test "rejects a nil refresh token", %{client: client} do
      assert {:error, :invalid_grant} =
               OAuth.refresh_access_token(%{"client_id" => client.client_id}, @base)
    end
  end

  describe "verify_access_token/2" do
    test "rejects an expired token", %{client: client, user: user} do
      code = issue_code(client, user)
      {:ok, tokens} = OAuth.exchange_authorization_code(exchange_params(client, code), @base)

      Repo.update_all(Token,
        set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second)]
      )

      assert {:error, :invalid_token} = OAuth.verify_access_token(tokens.access_token, @base)
    end

    test "rejects a token whose audience is another server", %{client: client, user: user} do
      code = issue_code(client, user)
      {:ok, tokens} = OAuth.exchange_authorization_code(exchange_params(client, code), @base)

      assert {:error, :invalid_token} =
               OAuth.verify_access_token(tokens.access_token, "https://other.example")
    end

    test "rejects a token for a user who is no longer approved", %{client: client, user: user} do
      code = issue_code(client, user)
      {:ok, tokens} = OAuth.exchange_authorization_code(exchange_params(client, code), @base)
      {:ok, _} = Accounts.revoke_user(user)
      assert {:error, :invalid_token} = OAuth.verify_access_token(tokens.access_token, @base)
    end

    test "rejects garbage and nil" do
      assert {:error, :invalid_token} = OAuth.verify_access_token("nope", @base)
      assert {:error, :invalid_token} = OAuth.verify_access_token(nil, @base)
    end
  end

  describe "cleanup/0" do
    test "removes expired codes and revoked tokens", %{client: client, user: user} do
      code = issue_code(client, user)
      {:ok, first} = OAuth.exchange_authorization_code(exchange_params(client, code), @base)

      {:ok, _} =
        OAuth.refresh_access_token(
          %{"client_id" => client.client_id, "refresh_token" => first.refresh_token},
          @base
        )

      Repo.update_all(AuthorizationCode,
        set: [expires_at: DateTime.add(DateTime.utc_now(:second), -1, :second)]
      )

      assert %{codes: 1, tokens: 1} = OAuth.cleanup()
      assert Repo.aggregate(Token, :count) == 1
      assert Secret.hash("x") != nil
    end
  end
end
