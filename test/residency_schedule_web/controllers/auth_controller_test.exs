defmodule ResidencyScheduleWeb.AuthControllerTest do
  use ResidencyScheduleWeb.ConnCase

  # ── Site login ──────────────────────────────────────────────────────────────

  describe "GET /login" do
    test "renders the login form", %{conn: conn} do
      conn = get(conn, "/login")
      assert html_response(conn, 200) =~ "Sign in"
    end
  end

  describe "POST /login" do
    test "sets session and redirects to / on correct site password", %{conn: conn} do
      conn = post(conn, "/login", %{"password" => "dev-password"})
      assert redirected_to(conn) == "/"
      assert get_session(conn, :authenticated) == true
      assert get_session(conn, :resident_id) == nil
    end

    test "sets session with resident_id on valid resident name", %{conn: conn} do
      seed_schedule()
      conn = post(conn, "/login", %{"password" => "Alexis"})
      assert redirected_to(conn) =~ "/residents/"
      assert get_session(conn, :authenticated) == true
      assert get_session(conn, :resident_id) != nil
    end

    test "re-renders login form with error on wrong password", %{conn: conn} do
      conn = post(conn, "/login", %{"password" => "wrong"})
      assert html_response(conn, 200) =~ "Incorrect password"
    end
  end

  describe "POST /logout" do
    test "clears all session keys and redirects to /login", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(authenticated: true, resident_id: 1, admin: true)
        |> post("/logout")

      assert redirected_to(conn) == "/login"
      assert get_session(conn, :authenticated) == nil
      assert get_session(conn, :resident_id) == nil
      assert get_session(conn, :admin) == nil
    end
  end

  # ── set_home / unset_home ───────────────────────────────────────────────────

  describe "POST /set-home/:resident_id" do
    setup :authenticate_session

    test "sets resident_id in session and redirects to resident page", %{conn: conn} do
      conn = post(conn, "/set-home/42")
      assert redirected_to(conn) == "/residents/42"
      assert get_session(conn, :resident_id) == 42
    end
  end

  describe "POST /unset-home" do
    setup :authenticate_session

    test "clears resident_id from session and redirects to resident page", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(authenticated: true, resident_id: 42)
        |> post("/unset-home", %{"resident_id" => "42"})

      assert redirected_to(conn) == "/residents/42"
      assert get_session(conn, :resident_id) == nil
    end
  end

  # ── Admin login ─────────────────────────────────────────────────────────────

  describe "GET /admin/login" do
    test "renders the admin login form without site authentication", %{conn: conn} do
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
