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
    test "logs in approved user with existing password", %{conn: conn} do
      {:ok, user} = Accounts.create_user(%{email: "verify@urmc.rochester.edu"})
      Accounts.set_password(user, "testpassword123")
      {:ok, token} = Accounts.generate_magic_link_token(user)

      conn = get(conn, "/auth/verify", %{"token" => token})
      assert redirected_to(conn) == "/"
      assert get_session(conn, :user_id) == user.id
    end

    test "shows set-password form for user without password", %{conn: conn} do
      {:ok, user} = Accounts.create_user(%{email: "new@urmc.rochester.edu"})
      {:ok, token} = Accounts.generate_magic_link_token(user)

      conn = get(conn, "/auth/verify", %{"token" => token})
      assert html_response(conn, 200) =~ "set a password"
    end

    test "rejects invalid token", %{conn: conn} do
      conn = get(conn, "/auth/verify", %{"token" => "bogus"})
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
        |> Plug.Test.init_test_session(user_id: 1, authenticated: true, admin: true)
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

      conn = get(conn, "/auth/verify", %{"token" => token})
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
  end

  # ── Admin login ────────────────────────────────────────────────────────────

  describe "GET /admin/login" do
    test "renders the admin login form", %{conn: conn} do
      conn = get(conn, "/admin/login")
      assert html_response(conn, 200) =~ "Admin"
    end
  end

  describe "POST /admin/login" do
    test "sets admin session and redirects to /admin on correct password", %{conn: conn} do
      conn = post(conn, "/admin/login", %{"password" => "admin"})
      assert redirected_to(conn) == "/admin"
      assert get_session(conn, :admin) == true
      assert get_session(conn, :authenticated) == true
    end

    test "re-renders admin login with error on wrong password", %{conn: conn} do
      conn = post(conn, "/admin/login", %{"password" => "wrong"})
      assert html_response(conn, 200) =~ "Incorrect admin password"
    end
  end

  describe "POST /admin/logout" do
    test "clears admin session and redirects to /admin/login", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(authenticated: true, admin: true)
        |> post("/admin/logout")

      assert redirected_to(conn) == "/admin/login"
      assert get_session(conn, :admin) == nil
    end
  end
end
