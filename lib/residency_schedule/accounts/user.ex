defmodule ResidencySchedule.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :password_hash, :string
    field :approved, :boolean, default: false

    belongs_to :home_resident, ResidencySchedule.Residents.ScheduleResident

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a user via magic link signup.

      iex> cs = ResidencySchedule.Accounts.User.registration_changeset(
      ...>   %ResidencySchedule.Accounts.User{},
      ...>   %{email: "test@urmc.rochester.edu"}
      ...> )
      iex> cs.valid?
      true
  """
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/, message: "must be a valid email")
    |> unique_constraint(:email)
    |> maybe_auto_approve()
  end

  @doc """
  Changeset for setting or updating a password.

      iex> cs = ResidencySchedule.Accounts.User.password_changeset(
      ...>   %ResidencySchedule.Accounts.User{},
      ...>   %{password: "mysecretpassword"}
      ...> )
      iex> cs.valid?
      true
  """
  def password_changeset(user, attrs) do
    user
    |> cast(attrs, [])
    |> put_password_hash(attrs)
  end

  @doc """
  Changeset for updating the home resident link.

      iex> cs = ResidencySchedule.Accounts.User.home_resident_changeset(
      ...>   %ResidencySchedule.Accounts.User{},
      ...>   %{home_resident_id: 1}
      ...> )
      iex> cs.valid?
      true
  """
  def home_resident_changeset(user, attrs) do
    user
    |> cast(attrs, [:home_resident_id])
  end

  @doc """
  Changeset for approving a user.

      iex> cs = ResidencySchedule.Accounts.User.approval_changeset(
      ...>   %ResidencySchedule.Accounts.User{},
      ...>   %{approved: true}
      ...> )
      iex> cs.valid?
      true
  """
  def approval_changeset(user, attrs) do
    user
    |> cast(attrs, [:approved])
  end

  @doc """
  Returns true if the email belongs to the URMC domain.

      iex> ResidencySchedule.Accounts.User.urmc_email?("jane@urmc.rochester.edu")
      true

      iex> ResidencySchedule.Accounts.User.urmc_email?("jane@gmail.com")
      false
  """
  def urmc_email?(email) do
    email
    |> String.downcase()
    |> String.ends_with?("@urmc.rochester.edu")
  end

  @doc """
  Verifies a plaintext password against the stored hash. Returns false if
  no password_hash is set.

      iex> ResidencySchedule.Accounts.User.valid_password?(
      ...>   %ResidencySchedule.Accounts.User{password_hash: nil},
      ...>   "anything"
      ...> )
      false
  """
  def valid_password?(%__MODULE__{password_hash: nil}, _password), do: false

  def valid_password?(%__MODULE__{password_hash: hash}, password) do
    Bcrypt.verify_pass(password, hash)
  end

  defp maybe_auto_approve(changeset) do
    case get_change(changeset, :email) do
      nil -> changeset
      email -> if urmc_email?(email), do: put_change(changeset, :approved, true), else: changeset
    end
  end

  defp put_password_hash(changeset, %{password: password}) when byte_size(password) > 0 do
    if byte_size(password) < 8 do
      add_error(changeset, :password, "must be at least 8 characters")
    else
      put_change(changeset, :password_hash, Bcrypt.hash_pwd_salt(password))
    end
  end

  defp put_password_hash(changeset, %{"password" => password}) when byte_size(password) > 0 do
    put_password_hash(changeset, %{password: password})
  end

  defp put_password_hash(changeset, _attrs), do: changeset
end
