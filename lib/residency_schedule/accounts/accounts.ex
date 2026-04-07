defmodule ResidencySchedule.Accounts do
  @moduledoc """
  Context for user accounts, magic link tokens, and authentication.
  """

  import Ecto.Query
  alias ResidencySchedule.Repo
  alias ResidencySchedule.Accounts.User
  alias ResidencySchedule.Accounts.MagicLinkToken

  # ── User CRUD ���─────────────────────────────────────────────────────────────

  @doc """
  Gets a user by id. Returns nil if not found.
  Preloads home_resident.

  Exempt from doctest — hits the database.
  """
  def get_user(id) do
    User
    |> Repo.get(id)
    |> Repo.preload(:home_resident)
  end

  @doc """
  Gets a user by id. Raises if not found.
  Preloads home_resident.

  Exempt from doctest — hits the database.
  """
  def get_user!(id) do
    User
    |> Repo.get!(id)
    |> Repo.preload(:home_resident)
  end

  @doc """
  Finds a user by email (case-insensitive). Returns nil if not found.

  Exempt from doctest — hits the database.
  """
  def get_user_by_email(email) do
    trimmed = String.trim(email)

    from(u in User, where: u.email == ^trimmed)
    |> Repo.one()
  end

  @doc """
  Creates a new user from an email address. Auto-approves URMC emails.
  Returns `{:ok, user}` or `{:error, changeset}`.

  Exempt from doctest — hits the database.
  """
  def create_user(attrs) do
    %User{}
    |> User.registration_changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Finds an existing user by email, or creates a new one.
  Returns `{:ok, user}`.

  Exempt from doctest — hits the database.
  """
  def find_or_create_user_by_email(email) do
    case get_user_by_email(email) do
      nil -> create_user(%{email: String.trim(email)})
      user -> {:ok, user}
    end
  end

  @doc """
  Returns true if the user has a password set.

      iex> ResidencySchedule.Accounts.has_password?(%ResidencySchedule.Accounts.User{password_hash: nil})
      false

      iex> ResidencySchedule.Accounts.has_password?(%ResidencySchedule.Accounts.User{password_hash: "$2b$12$abc"})
      true
  """
  def has_password?(%User{password_hash: nil}), do: false
  def has_password?(%User{}), do: true

  @doc """
  Sets or updates the user's password.
  Returns `{:ok, user}` or `{:error, changeset}`.

  Exempt from doctest — hits the database.
  """
  def set_password(user, password) do
    user
    |> User.password_changeset(%{password: password})
    |> Repo.update()
  end

  @doc """
  Authenticates a user by email and password.
  Returns `{:ok, user}` or `{:error, :invalid_credentials}`.

  Exempt from doctest — hits the database.
  """
  def authenticate_by_password(email, password) do
    user = get_user_by_email(email)

    cond do
      user && User.valid_password?(user, password) ->
        {:ok, user}

      user ->
        {:error, :invalid_credentials}

      true ->
        Bcrypt.no_user_verify()
        {:error, :invalid_credentials}
    end
  end

  # ── Home resident ──────────────────────────────────────────────────────────

  @doc """
  Sets the user's home resident.
  Returns `{:ok, user}` or `{:error, changeset}`.

  Exempt from doctest — hits the database.
  """
  def set_home_resident(user, resident_id) do
    user
    |> User.home_resident_changeset(%{home_resident_id: resident_id})
    |> Repo.update()
  end

  @doc """
  Clears the user's home resident.
  Returns `{:ok, user}` or `{:error, changeset}`.

  Exempt from doctest — hits the database.
  """
  def clear_home_resident(user) do
    user
    |> User.home_resident_changeset(%{home_resident_id: nil})
    |> Repo.update()
  end

  # ── Approval ───────────────────────────────────────────────────────────────

  @doc """
  Lists all users pending approval.

  Exempt from doctest — hits the database.
  """
  def list_pending_users do
    from(u in User, where: u.approved == false, order_by: [asc: u.inserted_at])
    |> Repo.all()
  end

  @doc """
  Lists all approved users.

  Exempt from doctest — hits the database.
  """
  def list_approved_users do
    from(u in User, where: u.approved == true, order_by: [asc: u.email])
    |> Repo.all()
  end

  @doc """
  Approves a user.
  Returns `{:ok, user}` or `{:error, changeset}`.

  Exempt from doctest — hits the database.
  """
  def approve_user(user) do
    user
    |> User.approval_changeset(%{approved: true})
    |> Repo.update()
  end

  @doc """
  Revokes approval from a user.
  Returns `{:ok, user}` or `{:error, changeset}`.

  Exempt from doctest — hits the database.
  """
  def revoke_user(user) do
    user
    |> User.approval_changeset(%{approved: false})
    |> Repo.update()
  end

  # ── Tour ───────────────────────────────────────────────────────────────────

  @doc """
  Marks the user's guided tour as completed.
  Returns `{:ok, user}` or `{:error, changeset}`.

  Exempt from doctest — hits the database.
  """
  def complete_tour(user) do
    user
    |> User.tour_changeset(%{tour_completed: true})
    |> Repo.update()
  end

  @doc """
  Resets the user's tour so it will show again on next visit.
  Returns `{:ok, user}` or `{:error, changeset}`.

  Exempt from doctest — hits the database.
  """
  def reset_tour(user) do
    user
    |> User.tour_changeset(%{tour_completed: false})
    |> Repo.update()
  end

  # ── Magic link tokens ──────────────────────────────────────────────────────

  @doc """
  Generates a magic link token for a user. Returns `{:ok, token_string}`.

  Exempt from doctest — hits the database.
  """
  def generate_magic_link_token(user) do
    token_string = Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
    expires_at = DateTime.add(DateTime.utc_now(), MagicLinkToken.validity_minutes(), :minute)

    %MagicLinkToken{}
    |> MagicLinkToken.changeset(%{
      user_id: user.id,
      token: token_string,
      expires_at: DateTime.truncate(expires_at, :second)
    })
    |> Repo.insert!()

    {:ok, token_string}
  end

  @doc """
  Verifies a magic link token. Returns `{:ok, user}` if valid, `{:error, reason}` otherwise.
  Marks the token as used on success.

  Exempt from doctest — hits the database.
  """
  def verify_magic_link_token(token_string) do
    now = DateTime.utc_now()

    query =
      from(t in MagicLinkToken,
        where: t.token == ^token_string and is_nil(t.used_at) and t.expires_at > ^now,
        preload: [:user]
      )

    case Repo.one(query) do
      nil ->
        {:error, :invalid_or_expired}

      token ->
        token
        |> MagicLinkToken.changeset(%{used_at: DateTime.truncate(now, :second)})
        |> Repo.update!()

        {:ok, token.user}
    end
  end

  @doc """
  Deletes expired and used tokens older than 24 hours. Returns `{count, nil}`.

  Exempt from doctest — hits the database.
  """
  def cleanup_tokens do
    cutoff = DateTime.add(DateTime.utc_now(), -24, :hour)

    from(t in MagicLinkToken,
      where: t.expires_at < ^cutoff or (not is_nil(t.used_at) and t.used_at < ^cutoff)
    )
    |> Repo.delete_all()
  end
end
