defmodule ResidencySchedule.Accounts.AdminCredential do
  use Ecto.Schema
  import Ecto.Changeset

  schema "admin_credentials" do
    field :password_hash, :string
    field :password, :string, virtual: true, redact: true

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for setting or updating the admin password. Validates length,
  then stores a bcrypt hash and discards the plaintext.

      iex> cs = ResidencySchedule.Accounts.AdminCredential.password_changeset(
      ...>   %ResidencySchedule.Accounts.AdminCredential{},
      ...>   %{password: "supersecret1"}
      ...> )
      iex> cs.valid?
      true
  """
  def password_changeset(credential, attrs) do
    credential
    |> cast(attrs, [:password])
    |> validate_required([:password])
    |> validate_length(:password, min: 8)
    |> hash_password()
  end

  @doc """
  Verifies a plaintext password against the stored hash. Returns false if
  no password_hash is set.

      iex> ResidencySchedule.Accounts.AdminCredential.valid_password?(
      ...>   %ResidencySchedule.Accounts.AdminCredential{
      ...>     password_hash: Bcrypt.hash_pwd_salt("supersecret1")
      ...>   },
      ...>   "supersecret1"
      ...> )
      true

      iex> ResidencySchedule.Accounts.AdminCredential.valid_password?(
      ...>   %ResidencySchedule.Accounts.AdminCredential{password_hash: nil},
      ...>   "anything"
      ...> )
      false
  """
  def valid_password?(%__MODULE__{password_hash: nil}, _password), do: false

  def valid_password?(%__MODULE__{password_hash: hash}, password) do
    Bcrypt.verify_pass(password, hash)
  end

  defp hash_password(changeset) do
    case {changeset.valid?, get_change(changeset, :password)} do
      {true, password} when is_binary(password) ->
        changeset
        |> put_change(:password_hash, Bcrypt.hash_pwd_salt(password))
        |> delete_change(:password)

      _ ->
        changeset
    end
  end
end
