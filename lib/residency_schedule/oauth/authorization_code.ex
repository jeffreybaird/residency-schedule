defmodule ResidencySchedule.OAuth.AuthorizationCode do
  @moduledoc """
  A single-use authorization code bound to a client, a user, a redirect URI,
  a PKCE challenge, and the resource it was requested for. Only the SHA-256
  hash of the code is stored.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @validity_seconds 600

  schema "oauth_authorization_codes" do
    field :code_hash, :string
    field :redirect_uri, :string
    field :code_challenge, :string
    field :code_challenge_method, :string, default: "S256"
    field :scope, :string
    field :resource, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    belongs_to :client, ResidencySchedule.OAuth.Client
    belongs_to :user, ResidencySchedule.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for issuing a code. Only the `S256` challenge method is accepted.

      iex> cs = ResidencySchedule.OAuth.AuthorizationCode.changeset(
      ...>   %ResidencySchedule.OAuth.AuthorizationCode{},
      ...>   %{code_hash: "h", client_id: 1, user_id: 1, redirect_uri: "https://a.example/cb",
      ...>     code_challenge: "c", code_challenge_method: "S256", expires_at: ~U[2026-09-06 12:00:00Z]}
      ...> )
      iex> cs.valid?
      true
  """
  def changeset(code, attrs) do
    code
    |> cast(attrs, [
      :code_hash,
      :client_id,
      :user_id,
      :redirect_uri,
      :code_challenge,
      :code_challenge_method,
      :scope,
      :resource,
      :expires_at,
      :used_at
    ])
    |> validate_required([
      :code_hash,
      :client_id,
      :user_id,
      :redirect_uri,
      :code_challenge,
      :code_challenge_method,
      :expires_at
    ])
    |> validate_inclusion(:code_challenge_method, ["S256"])
    |> unique_constraint(:code_hash)
  end

  @doc """
  Returns how long an authorization code stays valid, in seconds.

      iex> ResidencySchedule.OAuth.AuthorizationCode.validity_seconds()
      600
  """
  def validity_seconds, do: @validity_seconds
end
