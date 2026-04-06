defmodule ResidencySchedule.Accounts.MagicLinkToken do
  use Ecto.Schema
  import Ecto.Changeset

  @token_validity_minutes 15

  schema "magic_link_tokens" do
    field :token, :string
    field :expires_at, :utc_datetime
    field :used_at, :utc_datetime

    belongs_to :user, ResidencySchedule.Accounts.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a new magic link token.

      iex> cs = ResidencySchedule.Accounts.MagicLinkToken.changeset(
      ...>   %ResidencySchedule.Accounts.MagicLinkToken{},
      ...>   %{user_id: 1, token: "abc123", expires_at: DateTime.utc_now()}
      ...> )
      iex> cs.valid?
      true
  """
  def changeset(token_struct, attrs) do
    token_struct
    |> cast(attrs, [:user_id, :token, :expires_at, :used_at])
    |> validate_required([:user_id, :token, :expires_at])
    |> unique_constraint(:token)
  end

  @doc """
  Returns the token validity duration in minutes.

      iex> ResidencySchedule.Accounts.MagicLinkToken.validity_minutes()
      15
  """
  def validity_minutes, do: @token_validity_minutes
end
