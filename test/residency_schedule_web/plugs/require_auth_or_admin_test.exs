defmodule ResidencyScheduleWeb.Plugs.RequireAuthOrAdminTest do
  use ResidencyScheduleWeb.ConnCase

  alias ResidencySchedule.Accounts
  alias ResidencyScheduleWeb.Plugs.RequireAuthOrAdmin

  describe "call/2" do
    test "allows admin session without user_id" do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(admin: true, authenticated: true)
        |> RequireAuthOrAdmin.call([])

      refute conn.halted
      refute Map.has_key?(conn.assigns, :current_user)
    end

    test "allows admin session when user_id is also set" do
      {:ok, user} =
        Accounts.create_user(%{email: "both-#{System.unique_integer()}@urmc.rochester.edu"})

      conn =
        build_conn()
        |> Plug.Test.init_test_session(
          admin: true,
          authenticated: true,
          user_id: user.id
        )
        |> RequireAuthOrAdmin.call([])

      refute conn.halted
    end

    test "allows approved user without admin" do
      {:ok, user} =
        Accounts.create_user(%{email: "resident-#{System.unique_integer()}@urmc.rochester.edu"})

      conn =
        build_conn()
        |> Plug.Test.init_test_session(user_id: user.id, authenticated: true)
        |> RequireAuthOrAdmin.call([])

      refute conn.halted
      assert conn.assigns.current_user.id == user.id
    end

    test "halts when not admin and no user_id" do
      conn =
        build_conn()
        |> Plug.Test.init_test_session(authenticated: true)
        |> RequireAuthOrAdmin.call([])

      assert conn.halted
      assert redirected_to(conn) == "/login"
    end

    test "halts when user exists but is not approved" do
      {:ok, user} =
        Accounts.create_user(%{email: "pending-#{System.unique_integer()}@gmail.com"})

      refute user.approved

      conn =
        build_conn()
        |> Plug.Test.init_test_session(user_id: user.id, authenticated: true)
        |> RequireAuthOrAdmin.call([])

      assert conn.halted
      assert redirected_to(conn) == "/login"
    end
  end
end
