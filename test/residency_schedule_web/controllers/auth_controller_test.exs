defmodule ResidencyScheduleWeb.AuthControllerTest do
  use ResidencyScheduleWeb.ConnCase

  alias ResidencySchedule.Accounts

  # ── Login page ─────────────────────────────────────────────────────────────

  describe "GET /login" do
    test "renders the email login form", %{conn: conn} do
      conn = get(conn, "/login")
      assert html_response(conn, 200) =~ "Email address"
    end
  end

  # ── Email identification ───────────────────────────────────────────────────

  describe "POST /login/identify" do
    test "creates user and shows method choice for URMC email", %{conn: conn} do
      conn = post(conn, "/login/identify", %{"email" => "test@urmc.rochester.edu"})
      assert html_response(conn, 200) =~ "Send me a login link"
    end

    test "creates user and shows method choice for non-URMC email", %{conn: conn} do
      conn = post(conn, "/login/identify", %{"email" => "test@gmail.com"})
      assert html_response(conn, 200) =~ "Send me a login link"
    end

    test "shows password option when user has a password set", %{conn: conn} do
      {:ok, user} = Accounts.create_user(%{email: "pw@urmc.rochester.edu"})
      Accounts.set_password(user, "testpassword123")

      conn = post(conn, "/login/identify", %{"email" => "pw@urmc.rochester.edu"})
      assert html_response(conn, 200) =~ "Log in with password"
    end

    test "shows error for invalid email", %{conn: conn} do
      conn = post(conn, "/login/identify", %{"email" => ""})
      assert html_response(conn, 200) =~ "valid email"
    end
  end

  # ── Magic link send ──────────────────────────────────────────────��─────────

  describe "POST /login/send-link" do
    test "shows check-email screen", %{conn: conn} do
      {:ok, user} = Accounts.create_user(%{email: "magic@urmc.rochester.edu"})

      conn =
        conn
        |> Plug.Test.init_test_session(login_user_id: user.id)
        |> post("/login/send-link")

      assert html_response(conn, 200) =~ "sent a login link"
    end

    test "redirects to /login when session expired", %{conn: conn} do
      conn = post(conn, "/login/send-link")
      assert redirected_to(conn) == "/login"
    end
  end

  # ── Magic link verification ────────────────────────────────────────────────

  describe "GET /auth/verify" do
    test "shows the confirm prompt without consuming the token", %{conn: conn} do
      {:ok, user} = Accounts.create_user(%{email: "verify@urmc.rochester.edu"})
      Accounts.set_password(user, "testpassword123")
      {:ok, token} = Accounts.generate_magic_link_token(user)

      conn = get(conn, "/auth/verify", %{"token" => token})

      # The GET only shows the interstitial — it must not log the user in...
      assert html_response(conn, 200) =~ "Sign in"
      assert get_session(conn, :user_id) == nil

      # ...and the token must remain consumable (scanner pre-fetch safety).
      assert {:ok, _} = Accounts.consume_magic_link_token(token)
    end

    test "rejects invalid token", %{conn: conn} do
      conn = get(conn, "/auth/verify", %{"token" => "bogus"})
      assert redirected_to(conn) == "/login"
    end
  end

  describe "POST /auth/verify" do
    test "logs in approved user with existing password", %{conn: conn} do
      {:ok, user} = Accounts.create_user(%{email: "confirm@urmc.rochester.edu"})
      Accounts.set_password(user, "testpassword123")
      {:ok, token} = Accounts.generate_magic_link_token(user)

      conn = post(conn, "/auth/verify", %{"token" => token})
      assert redirected_to(conn) == "/"
      assert get_session(conn, :user_id) == user.id
    end

    test "shows set-password form for user without password", %{conn: conn} do
      {:ok, user} = Accounts.create_user(%{email: "confirmnew@urmc.rochester.edu"})
      {:ok, token} = Accounts.generate_magic_link_token(user)

      conn = post(conn, "/auth/verify", %{"token" => token})
      assert html_response(conn, 200) =~ "set a password"
    end

    test "rejects an already-consumed token", %{conn: conn} do
      {:ok, user} = Accounts.create_user(%{email: "confirmtwice@urmc.rochester.edu"})
      Accounts.set_password(user, "testpassword123")
      {:ok, token} = Accounts.generate_magic_link_token(user)

      post(conn, "/auth/verify", %{"token" => token})
      conn = post(conn, "/auth/verify", %{"token" => token})
      assert redirected_to(conn) == "/login"
    end

    test "rejects invalid token", %{conn: conn} do
      conn = post(conn, "/auth/verify", %{"token" => "bogus"})
      assert redirected_to(conn) == "/login"
    end
  end

  # ── Set initial password ───────────────────────────────────────────────────

  describe "POST /auth/set-password" do
    test "sets password and logs in", %{conn: conn} do
      {:ok, user} = Accounts.create_user(%{email: "setpw@urmc.rochester.edu"})

      conn =
        conn
        |> Plug.Test.init_test_session(verified_user_id: user.id)
        |> post("/auth/set-password", %{"password" => "mysecretpass"})

      assert redirected_to(conn) == "/"
      assert get_session(conn, :user_id) == user.id
      assert Accounts.has_password?(Accounts.get_user!(user.id))
    end

    test "skips password and logs in when password is empty", %{conn: conn} do
      {:ok, user} = Accounts.create_user(%{email: "skip@urmc.rochester.edu"})

      conn =
        conn
        |> Plug.Test.init_test_session(verified_user_id: user.id)
        |> post("/auth/set-password", %{"password" => ""})

      assert redirected_to(conn) == "/"
      refute Accounts.has_password?(Accounts.get_user!(user.id))
    end
  end

  # ── Password login ─────────────────────────────────────────────────────────

  describe "POST /login/password" do
    test "logs in with correct password", %{conn: conn} do
      {:ok, user} = Accounts.create_user(%{email: "pwlogin@urmc.rochester.edu"})
      Accounts.set_password(user, "correctpassword")

      conn =
        conn
        |> Plug.Test.init_test_session(login_user_id: user.id)
        |> post("/login/password", %{"password" => "correctpassword"})

      assert redirected_to(conn) == "/"
      assert get_session(conn, :user_id) == user.id
    end

    test "rejects wrong password", %{conn: conn} do
      {:ok, user} = Accounts.create_user(%{email: "pwfail@urmc.rochester.edu"})
      Accounts.set_password(user, "correctpassword")

      conn =
        conn
        |> Plug.Test.init_test_session(login_user_id: user.id)
        |> post("/login/password", %{"password" => "wrongpassword"})

      assert html_response(conn, 200) =~ "Incorrect password"
    end
  end

  # ── Logout ─────────────────────────────────────────────────────────────────

  describe "POST /logout" do
    test "drops session and redirects to /login", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(user_id: 1)
        |> post("/logout")

      assert redirected_to(conn) == "/login"
    end
  end

  # ── set_home / unset_home ──────────────────────────────────────────────────

  describe "POST /set-home/:resident_id" do
    setup :authenticate_session

    test "persists home_resident_id on user and redirects", %{conn: conn, user: user} do
      seed_schedule()
      resident = ResidencySchedule.Residents.get_resident_by_position!("R4-1")

      conn = post(conn, "/set-home/#{resident.id}")
      assert redirected_to(conn) == "/residents/#{resident.id}"

      updated_user = Accounts.get_user!(user.id)
      assert updated_user.home_resident_id == resident.id
    end
  end

  describe "POST /unset-home" do
    setup :authenticate_session

    test "clears home_resident_id on user and redirects", %{conn: conn, user: user} do
      seed_schedule()
      resident = ResidencySchedule.Residents.get_resident_by_position!("R4-1")
      Accounts.set_home_resident(user, resident.id)

      conn = post(conn, "/unset-home", %{"resident_id" => to_string(resident.id)})
      assert redirected_to(conn) == "/residents/#{resident.id}"

      updated_user = Accounts.get_user!(user.id)
      assert updated_user.home_resident_id == nil
    end
  end

  # ── Pending approval ───────────────────────────────────────���───────────────

  describe "pending approval flow" do
    test "unapproved user sees pending approval after magic link", %{conn: conn} do
      {:ok, user} = Accounts.create_user(%{email: "pending@gmail.com"})
      {:ok, token} = Accounts.generate_magic_link_token(user)

      conn = post(conn, "/auth/verify", %{"token" => token})
      # User has no password, so sees set-password form first
      assert html_response(conn, 200) =~ "set a password"

      # Skip password
      conn =
        conn
        |> recycle()
        |> Plug.Test.init_test_session(verified_user_id: user.id)
        |> post("/auth/set-password", %{"password" => ""})

      assert html_response(conn, 200) =~ "pending approval"
    end

    test "denied user sees the denial notice after logging in", %{conn: conn} do
      {:ok, user} = Accounts.create_user(%{email: "denied@gmail.com"})
      {:ok, denied} = Accounts.deny_user(user)
      {:ok, _updated} = Accounts.set_password(denied, "testpassword123")

      conn =
        conn
        |> Plug.Test.init_test_session(login_user_id: denied.id)
        |> post("/login/password", %{"password" => "testpassword123"})

      assert html_response(conn, 200) =~ "was not approved"
    end
  end

  # ── Session persistence ──────────────────────────────────────────────────

  describe "session persistence" do
    test "login sets a session cookie with 30-day max-age", %{conn: conn} do
      {:ok, user} = Accounts.create_user(%{email: "persist@urmc.rochester.edu"})
      Accounts.set_password(user, "testpassword123")

      conn =
        conn
        |> Plug.Test.init_test_session(login_user_id: user.id)
        |> post("/login/password", %{"password" => "testpassword123"})

      cookie_header =
        conn
        |> get_resp_header("set-cookie")
        |> Enum.find(&String.starts_with?(&1, "_residency_schedule_key"))

      assert cookie_header != nil
      assert cookie_header =~ "max-age=2592000"
    end
  end

  # ── Admin login ────────────────────────────────────────────────────────────

  describe "role-based /admin access" do
    test "an admin user can reach /admin", %{conn: conn} do
      %{conn: conn} = admin_authenticate_session(%{conn: conn})
      conn = get(conn, "/admin")
      assert html_response(conn, 200)
    end

    test "a resident is redirected from /admin to the site root", %{conn: conn} do
      %{conn: conn} = authenticate_session(%{conn: conn})
      conn = get(conn, "/admin")
      assert redirected_to(conn) == "/"
    end

    test "an anonymous visitor is redirected from /admin to /login", %{conn: conn} do
      conn = get(conn, "/admin")
      assert redirected_to(conn) == "/login"
    end

    test "an unapproved user is redirected from /admin to /login", %{conn: conn} do
      {:ok, user} = Accounts.create_user(%{email: "pending@gmail.com"})
      conn = Plug.Test.init_test_session(conn, user_id: user.id)
      conn = get(conn, "/admin")
      assert redirected_to(conn) == "/login"
    end
  end
end
