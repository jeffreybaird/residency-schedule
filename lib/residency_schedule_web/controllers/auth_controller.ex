defmodule ResidencyScheduleWeb.AuthController do
  use ResidencyScheduleWeb, :controller

  alias ResidencySchedule.Accounts
  alias ResidencySchedule.Mailer

  # ── Login page ───────────────────────────────────────────────────────────

  @doc """
  Renders the login form. Step 1: email input.
  """
  def show(conn, _params) do
    render(conn, :show, step: :email)
  end

  @doc """
  Handles email submission. Finds or creates user, then shows appropriate next step.
  """
  def identify(conn, %{"email" => email}) do
    case Accounts.find_or_create_user_by_email(email) do
      {:ok, user} ->
        conn
        |> put_session(:login_user_id, user.id)
        |> render(:show,
          step: :choose_method,
          email: user.email,
          has_password: Accounts.has_password?(user)
        )

      {:error, _changeset} ->
        conn
        |> put_flash(:error, "Please enter a valid email address.")
        |> render(:show, step: :email)
    end
  end

  @doc """
  Sends a magic link to the user identified in the session.
  """
  def send_magic_link(conn, _params) do
    user_id = get_session(conn, :login_user_id)
    user = user_id && Accounts.get_user(user_id)

    if user do
      {:ok, token} = Accounts.generate_magic_link_token(user)
      base_url = ResidencyScheduleWeb.Endpoint.url()
      Mailer.send_magic_link(user, token, base_url)

      conn
      |> delete_session(:login_user_id)
      |> render(:show, step: :check_email, email: user.email)
    else
      conn
      |> put_flash(:error, "Session expired. Please start over.")
      |> redirect(to: "/login")
    end
  end

  @doc """
  Handles password-based login.
  """
  def password_login(conn, %{"password" => password}) do
    user_id = get_session(conn, :login_user_id)
    user = user_id && Accounts.get_user(user_id)

    if user do
      case Accounts.authenticate_by_password(user.email, password) do
        {:ok, authed_user} ->
          conn
          |> delete_session(:login_user_id)
          |> log_in_user(authed_user)

        {:error, _} ->
          conn
          |> put_flash(:error, "Incorrect password.")
          |> render(:show,
            step: :choose_method,
            email: user.email,
            has_password: Accounts.has_password?(user)
          )
      end
    else
      conn
      |> put_flash(:error, "Session expired. Please start over.")
      |> redirect(to: "/login")
    end
  end

  # ── Magic link verification ────────────────────────────────────────────────

  @doc """
  Validates a magic link token from the email (GET) and shows a confirmation
  prompt. The token is not consumed here, so email scanners that pre-fetch the
  link cannot invalidate it before the user clicks through.
  """
  def verify(conn, %{"token" => token}) do
    case Accounts.validate_magic_link_token(token) do
      {:ok, user} ->
        render(conn, :show, step: :confirm_login, email: user.email, token: token)

      {:error, _} ->
        conn
        |> put_flash(:error, "This link is invalid or has expired. Please request a new one.")
        |> redirect(to: "/login")
    end
  end

  @doc """
  Consumes a magic link token (POST) and logs the user in.
  On first login (no password set), shows the optional set-password prompt.
  """
  def confirm(conn, %{"token" => token}) do
    case Accounts.consume_magic_link_token(token) do
      {:ok, user} ->
        if Accounts.has_password?(user) do
          log_in_user(conn, user)
        else
          conn
          |> put_session(:verified_user_id, user.id)
          |> render(:show, step: :set_password, email: user.email)
        end

      {:error, _} ->
        conn
        |> put_flash(:error, "This link is invalid or has expired. Please request a new one.")
        |> redirect(to: "/login")
    end
  end

  @doc """
  Handles the optional set-password form after magic link verification.
  """
  def set_initial_password(conn, params) do
    user_id = get_session(conn, :verified_user_id)
    user = user_id && Accounts.get_user(user_id)

    if user do
      password = Map.get(params, "password", "")

      if password != "" do
        case Accounts.set_password(user, password) do
          {:ok, updated_user} ->
            conn
            |> delete_session(:verified_user_id)
            |> log_in_user(updated_user)

          {:error, _changeset} ->
            conn
            |> put_flash(:error, "Password must be at least 8 characters.")
            |> render(:show, step: :set_password, email: user.email)
        end
      else
        # User clicked "skip"
        conn
        |> delete_session(:verified_user_id)
        |> log_in_user(user)
      end
    else
      conn
      |> put_flash(:error, "Session expired. Please start over.")
      |> redirect(to: "/login")
    end
  end

  # ── Logout ─────────────────────────────────────────────────────────────────

  @doc """
  Logs the user out by clearing the session.
  """
  def delete(conn, _params) do
    conn
    |> configure_session(drop: true)
    |> redirect(to: "/login")
  end

  # ── Set/unset home resident ────────────────────────────────────────────────

  @doc """
  Sets the current user's home resident. Persists on the user record.
  """
  def set_home(conn, %{"resident_id" => resident_id}) do
    user_id = get_session(conn, :user_id)
    user = user_id && Accounts.get_user(user_id)

    if user do
      Accounts.set_home_resident(user, String.to_integer(resident_id))
    end

    redirect(conn, to: "/residents/#{resident_id}")
  end

  @doc """
  Clears the current user's home resident.
  """
  def unset_home(conn, %{"resident_id" => id}) do
    user_id = get_session(conn, :user_id)
    user = user_id && Accounts.get_user(user_id)

    if user do
      Accounts.clear_home_resident(user)
    end

    redirect(conn, to: "/residents/#{id}")
  end

  # ── Private helpers ────────────────────────────────────────────────────────

  defp log_in_user(conn, user) do
    conn =
      conn
      |> configure_session(renew: true)
      |> put_session(:user_id, user.id)

    if user.approved do
      # Home is the calendar at "/". When a user has an assigned resident the
      # calendar opens filtered to them; the resident detail page stays reachable
      # via the "My page" nav link.
      redirect(conn, to: "/")
    else
      render(conn, :show, step: :pending_approval, email: user.email)
    end
  end
end
