defmodule ResidencyScheduleWeb.AuthControllerTest do
  use ResidencyScheduleWeb.ConnCase

  describe "GET /login" do
    test "renders the login form", %{conn: conn} do
      conn = get(conn, "/login")
      assert html_response(conn, 200) =~ "Sign in"
    end
  end

  describe "POST /login" do
    test "sets session and redirects to / on correct password", %{conn: conn} do
      conn = post(conn, "/login", %{"password" => "dev-password"})
      assert redirected_to(conn) == "/"
      assert get_session(conn, :authenticated) == true
    end

    test "re-renders login form with error on wrong password", %{conn: conn} do
      conn = post(conn, "/login", %{"password" => "wrong"})
      assert html_response(conn, 200) =~ "Incorrect password"
    end
  end

  describe "POST /logout" do
    test "clears session and redirects to /login", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(authenticated: true)
        |> post("/logout")

      assert redirected_to(conn) == "/login"
      assert get_session(conn, :authenticated) == nil
    end
  end
end
