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
    with {:ok, user} <-
           %User{}
           |> User.registration_changeset(attrs)
           |> Repo.insert() do
      unless user.approved, do: notify_admin_of_pending_user(user)
      {:ok, user}
    end
  end

  defp notify_admin_of_pending_user(user) do
    base_url = ResidencyScheduleWeb.Endpoint.url()
    ResidencySchedule.Mailer.send_approval_request_email(user, base_url)
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
  Changes the user's own password. When the user already has a password, the
  current one must be provided and match; when none is set yet, the current
  password is ignored.

  Returns `{:ok, user}`, `{:error, :invalid_current_password}`, or
  `{:error, changeset}` when the new password fails validation.

  Exempt from doctest — hits the database.
  """
  def change_password(user, current_password, new_password) do
    if password_change_allowed?(user, current_password) do
      set_password(user, new_password)
    else
      {:error, :invalid_current_password}
    end
  end

  defp password_change_allowed?(user, current_password) do
    not has_password?(user) or User.valid_password?(user, current_password)
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

  # ── Roles ──────────────────────────────────────────────────────────────────

  @doc """
  Changes a user's role. Promoting to admin also approves the user so the
  account can log in immediately.

  Returns `{:ok, user}`, `{:error, :last_admin}` when demoting the only
  remaining admin, or `{:error, changeset}` when the role change is invalid
  (e.g. the resident role without a URMC email).

  Exempt from doctest — hits the database.
  """
  def set_role(user, role) do
    Repo.transaction(fn ->
      if demoting_last_admin?(user, role) do
        Repo.rollback(:last_admin)
      else
        user
        |> User.role_changeset(%{role: role})
        |> approve_on_admin_promotion(role)
        |> Repo.update()
        |> case do
          {:ok, updated} -> updated
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end
    end)
  end

  @doc """
  Lists all admins ordered by email.

  Exempt from doctest — hits the database.
  """
  def list_admins do
    from(u in User, where: u.role == :admin, order_by: [asc: u.email])
    |> Repo.all()
  end

  defp demoting_last_admin?(user, role) do
    user.role == :admin and role != :admin and count_locked_admins() == 1
  end

  # Locks the admin rows FOR UPDATE so concurrent demotions serialize: a second
  # demotion blocks here until the first commits, then re-reads the reduced set
  # and correctly sees itself as the last admin. Must run inside a transaction
  # (set_role wraps it) for the lock to be held until commit. Aggregates can't
  # carry FOR UPDATE in Postgres, so we lock the rows and count them in Elixir.
  defp count_locked_admins do
    from(u in User, where: u.role == :admin, lock: "FOR UPDATE")
    |> Repo.all()
    |> length()
  end

  defp approve_on_admin_promotion(changeset, :admin) do
    Ecto.Changeset.put_change(changeset, :approved, true)
  end

  defp approve_on_admin_promotion(changeset, _role), do: changeset

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
    with {:ok, approved_user} <-
           user
           |> User.approval_changeset(%{approved: true})
           |> Repo.update() do
      send_approval_notification(approved_user)
      {:ok, approved_user}
    end
  end

  defp send_approval_notification(user) do
    base_url = ResidencyScheduleWeb.Endpoint.url()
    ResidencySchedule.Mailer.send_approval_email(user, base_url)
  end

  @doc """
  Revokes approval from a user. Admins cannot be revoked — demote the admin
  role first — so a revoked account can never be the only working admin.
  Returns `{:ok, user}`, `{:error, :admin_cannot_be_revoked}`, or
  `{:error, changeset}`.

  Exempt from doctest — hits the database.
  """
  def revoke_user(%User{role: :admin}), do: {:error, :admin_cannot_be_revoked}

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
  Validates a magic link token without consuming it. Returns `{:ok, user}` if the
  token is active (unused and unexpired), `{:error, :invalid_or_expired}` otherwise.

  This is safe to call from a GET request: it does not mark the token as used, so
  email security scanners that pre-fetch links cannot burn the token.

  Exempt from doctest — hits the database.
  """
  def validate_magic_link_token(token_string) do
    case fetch_active_token(token_string) do
      nil -> {:error, :invalid_or_expired}
      token -> {:ok, token.user}
    end
  end

  @doc """
  Consumes a magic link token, marking it as used. Returns `{:ok, user}` if the
  token was active, `{:error, :invalid_or_expired}` otherwise.

  Call this only from a state-changing request (POST), never from a GET.

  Exempt from doctest — hits the database.
  """
  def consume_magic_link_token(token_string) do
    case fetch_active_token(token_string) do
      nil ->
        {:error, :invalid_or_expired}

      token ->
        token
        |> MagicLinkToken.changeset(%{used_at: DateTime.truncate(DateTime.utc_now(), :second)})
        |> Repo.update!()

        {:ok, token.user}
    end
  end

  defp fetch_active_token(token_string) do
    now = DateTime.utc_now()

    from(t in MagicLinkToken,
      where: t.token == ^token_string and is_nil(t.used_at) and t.expires_at > ^now,
      preload: [:user]
    )
    |> Repo.one()
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
