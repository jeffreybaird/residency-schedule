defmodule ResidencyScheduleWeb.UserAuthTest do
  use ResidencySchedule.DataCase, async: true

  alias ResidencySchedule.Accounts
  alias ResidencyScheduleWeb.UserAuth

  defp socket, do: %Phoenix.LiveView.Socket{}

  describe "on_mount :ensure_authenticated" do
    test "continues and assigns current_user for an approved user" do
      {:ok, user} = Accounts.create_user(%{email: "jane@urmc.rochester.edu"})

      assert {:cont, socket} =
               UserAuth.on_mount(:ensure_authenticated, %{}, %{"user_id" => user.id}, socket())

      assert socket.assigns.current_user.id == user.id
    end

    test "halts with a redirect to /login when the session has no user" do
      assert {:halt, socket} = UserAuth.on_mount(:ensure_authenticated, %{}, %{}, socket())
      assert {:redirect, %{to: "/login"}} = socket.redirected
    end

    test "halts for an unapproved user" do
      {:ok, user} = Accounts.create_user(%{email: "pending@gmail.com"})

      assert {:halt, socket} =
               UserAuth.on_mount(:ensure_authenticated, %{}, %{"user_id" => user.id}, socket())

      assert {:redirect, %{to: "/login"}} = socket.redirected
    end
  end

  describe "on_mount :ensure_admin" do
    test "continues and assigns current_user for an admin" do
      {:ok, user} = Accounts.create_user(%{email: "boss@gmail.com"})
      {:ok, admin} = Accounts.set_role(user, :admin)

      assert {:cont, socket} =
               UserAuth.on_mount(:ensure_admin, %{}, %{"user_id" => admin.id}, socket())

      assert socket.assigns.current_user.id == admin.id
    end

    test "halts with a redirect to / for an approved non-admin" do
      {:ok, resident} = Accounts.create_user(%{email: "jane@urmc.rochester.edu"})

      assert {:halt, socket} =
               UserAuth.on_mount(:ensure_admin, %{}, %{"user_id" => resident.id}, socket())

      assert {:redirect, %{to: "/"}} = socket.redirected
    end

    test "halts with a redirect to /login for an anonymous session" do
      assert {:halt, socket} = UserAuth.on_mount(:ensure_admin, %{}, %{}, socket())
      assert {:redirect, %{to: "/login"}} = socket.redirected
    end
  end
end
