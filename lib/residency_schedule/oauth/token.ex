defmodule ResidencySchedule.OAuth.Token do
  @moduledoc """
  An issued access token (and its paired refresh token). Only SHA-256 hashes
  are stored. `resource` records the audience the token was issued for so the
  MCP endpoint can reject tokens minted for anything else.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @access_validity_seconds 3600

  schema "oauth_tokens" do
    field :access_token_hash, :string
    field :refresh_token_hash, :string
    field :scope, :string
    field :resource, :string
    field :expires_at, :utc_datetime
    field :revoked_at, :utc_datetime

    belongs_to :client, ResidencySchedule.OAuth.Client
    belongs_to :user, ResidencySchedule.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for issuing a token pair.

      iex> cs = ResidencySchedule.OAuth.Token.changeset(
      ...>   %ResidencySchedule.OAuth.Token{},
      ...>   %{access_token_hash: "a", refresh_token_hash: "r", client_id: 1, user_id: 1,
      ...>     resource: "https://app.example/mcp", expires_at: ~U[2026-09-06 12:00:00Z]}
      ...> )
      iex> cs.valid?
      true
  """
  def changeset(token, attrs) do
    token
    |> cast(attrs, [
      :access_token_hash,
      :refresh_token_hash,
      :client_id,
      :user_id,
      :scope,
      :resource,
      :expires_at,
      :revoked_at
    ])
    |> validate_required([:access_token_hash, :client_id, :user_id, :resource, :expires_at])
    |> unique_constraint(:access_token_hash)
    |> unique_constraint(:refresh_token_hash)
  end

  @doc """
  Returns how long an access token stays valid, in seconds.

      iex> ResidencySchedule.OAuth.Token.access_validity_seconds()
      3600
  """
  def access_validity_seconds, do: @access_validity_seconds
end
