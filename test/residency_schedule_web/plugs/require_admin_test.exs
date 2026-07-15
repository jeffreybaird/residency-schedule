defmodule ResidencyScheduleWeb.Plugs.RequireAdminTest do
  use ResidencyScheduleWeb.ConnCase, async: true

  alias ResidencySchedule.Accounts
  alias ResidencyScheduleWeb.Plugs.RequireAdmin

  doctest RequireAdmin

  test "assigns current_user and continues for an admin", %{conn: conn} do
    admin = create_admin()

    conn =
      conn
      |> Plug.Test.init_test_session(user_id: admin.id)
      |> RequireAdmin.call([])

    refute conn.halted
    assert conn.assigns.current_user.id == admin.id
  end

  test "redirects an approved non-admin to the site root", %{conn: conn} do
    {:ok, resident} = Accounts.create_user(%{email: "resident@urmc.rochester.edu"})

    conn =
      conn
      |> Plug.Test.init_test_session(user_id: resident.id)
      |> RequireAdmin.call([])

    assert conn.halted
    assert redirected_to(conn) == "/"
  end

  test "redirects an unapproved user to /login", %{conn: conn} do
    {:ok, pending} = Accounts.create_user(%{email: "pending@gmail.com"})

    conn =
      conn
      |> Plug.Test.init_test_session(user_id: pending.id)
      |> RequireAdmin.call([])

    assert conn.halted
    assert redirected_to(conn) == "/login"
  end

  test "redirects an anonymous visitor to /login", %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(%{})
      |> RequireAdmin.call([])

    assert conn.halted
    assert redirected_to(conn) == "/login"
  end

  test "redirects a session pointing at a deleted user to /login", %{conn: conn} do
    conn =
      conn
      |> Plug.Test.init_test_session(user_id: 999_999)
      |> RequireAdmin.call([])

    assert conn.halted
    assert redirected_to(conn) == "/login"
  end
end
