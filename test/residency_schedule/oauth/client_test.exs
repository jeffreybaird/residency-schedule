defmodule ResidencySchedule.OAuth.ClientTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.OAuth.{AuthorizationCode, Client, Token}

  doctest Client
  doctest AuthorizationCode
  doctest Token

  describe "changeset/2" do
    test "rejects an empty redirect list" do
      cs = Client.changeset(%Client{}, %{client_id: "a", redirect_uris: []})
      refute cs.valid?
      assert %{redirect_uris: _} = errors(cs)
    end

    test "rejects a plain-http remote redirect" do
      cs = Client.changeset(%Client{}, %{client_id: "a", redirect_uris: ["http://x.example/cb"]})
      refute cs.valid?
    end

    test "rejects an unknown auth method" do
      cs =
        Client.changeset(%Client{}, %{
          client_id: "a",
          redirect_uris: ["https://x.example/cb"],
          token_endpoint_auth_method: "private_key_jwt"
        })

      refute cs.valid?
    end
  end

  describe "valid_redirect_uri?/1" do
    test "rejects a non-string" do
      refute Client.valid_redirect_uri?(nil)
    end

    test "rejects https without a host" do
      refute Client.valid_redirect_uri?("https:///cb")
    end
  end

  describe "AuthorizationCode.changeset/2" do
    test "rejects the plain challenge method" do
      cs =
        AuthorizationCode.changeset(%AuthorizationCode{}, %{
          code_hash: "h",
          client_id: 1,
          user_id: 1,
          redirect_uri: "https://a.example/cb",
          code_challenge: "c",
          code_challenge_method: "plain",
          expires_at: ~U[2026-09-06 12:00:00Z]
        })

      refute cs.valid?
    end
  end

  defp errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, _} -> msg end)
  end
end
