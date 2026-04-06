defmodule ResidencyScheduleWeb.PageControllerTest do
  use ResidencyScheduleWeb.ConnCase

  test "GET / redirects to /login when unauthenticated", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == "/login"
  end

  test "GET /login renders login form", %{conn: conn} do
    conn = get(conn, ~p"/login")
    assert html_response(conn, 200) =~ "Email address"
  end
end
