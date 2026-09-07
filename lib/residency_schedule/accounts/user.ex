defmodule ResidencySchedule.Accounts.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :password_hash, :string
    field :role, Ecto.Enum, values: [:user, :resident, :admin], default: :user
    field :approved, :boolean, default: false
    field :denied, :boolean, default: false
    field :tour_completed, :boolean, default: false

    belongs_to :home_resident, ResidencySchedule.Residents.Resident

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a user via magic link signup. URMC emails register
  as auto-approved residents; every other email registers with the default
  user role, pending admin approval.

      iex> cs = ResidencySchedule.Accounts.User.registration_changeset(
      ...>   %ResidencySchedule.Accounts.User{},
      ...>   %{email: "test@urmc.rochester.edu"}
      ...> )
      iex> {cs.valid?, Ecto.Changeset.get_field(cs, :role)}
      {true, :resident}
  """
  def registration_changeset(user, attrs) do
    user
    |> cast(attrs, [:email])
    |> validate_required([:email])
    |> validate_format(:email, ~r/^[^\s]+@[^\s]+\.[^\s]+$/, message: "must be a valid email")
    |> unique_constraint(:email)
    |> assign_role_from_email()
  end

  @doc """
  Changeset for changing a user's role. The resident role requires a URMC
  email address.

      iex> cs = ResidencySchedule.Accounts.User.role_changeset(
      ...>   %ResidencySchedule.Accounts.User{email: "partner@gmail.com", role: :user},
      ...>   %{role: :admin}
      ...> )
      iex> cs.valid?
      true
  """
  def role_changeset(user, attrs) do
    user
    |> cast(attrs, [:role])
    |> validate_required([:role])
    |> validate_resident_has_urmc_email()
  end

  @doc """
  Returns true when the user has the admin role.

      iex> ResidencySchedule.Accounts.User.admin?(%ResidencySchedule.Accounts.User{role: :admin})
      true

      iex> ResidencySchedule.Accounts.User.admin?(%ResidencySchedule.Accounts.User{role: :resident})
      false
  """
  def admin?(%__MODULE__{role: :admin}), do: true
  def admin?(_user), do: false

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
  Changeset for denying a pending user or reinstating a denied one. Setting
  `denied` to true soft-rejects the account; setting it to false returns the
  account to the pending state so the user can try again.

      iex> cs = ResidencySchedule.Accounts.User.denial_changeset(
      ...>   %ResidencySchedule.Accounts.User{},
      ...>   %{denied: true}
      ...> )
      iex> {cs.valid?, Ecto.Changeset.get_field(cs, :denied)}
      {true, true}
  """
  def denial_changeset(user, attrs) do
    user
    |> cast(attrs, [:denied])
  end

  @doc """
  Changeset for marking the tour as completed.

      iex> cs = ResidencySchedule.Accounts.User.tour_changeset(
      ...>   %ResidencySchedule.Accounts.User{},
      ...>   %{tour_completed: true}
      ...> )
      iex> cs.valid?
      true
  """
  def tour_changeset(user, attrs) do
    user
    |> cast(attrs, [:tour_completed])
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

  defp assign_role_from_email(changeset) do
    case get_change(changeset, :email) do
      nil ->
        changeset

      email ->
        if urmc_email?(email) do
          changeset
          |> put_change(:role, :resident)
          |> put_change(:approved, true)
        else
          changeset
        end
    end
  end

  defp validate_resident_has_urmc_email(changeset) do
    if get_change(changeset, :role) == :resident and
         not urmc_email?(get_field(changeset, :email) || "") do
      add_error(changeset, :role, "resident role requires a URMC email address")
    else
      changeset
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

  defp put_password_hash(changeset, _attrs) do
    add_error(changeset, :password, "can't be blank")
  end
end
