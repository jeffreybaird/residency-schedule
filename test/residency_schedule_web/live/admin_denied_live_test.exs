defmodule ResidencyScheduleWeb.AdminLive.DeniedTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest

  alias ResidencySchedule.Accounts

  describe "access control" do
    test "redirects an approved non-admin to the site root", %{conn: conn} do
      %{conn: conn} = authenticate_session(%{conn: conn})
      conn = get(conn, "/admin/denied")
      assert redirected_to(conn) == "/"
    end
  end

  describe "denied users page" do
    setup %{conn: conn} do
      %{conn: conn} = admin_authenticate_session(%{conn: conn})
      %{conn: conn}
    end

    test "lists denied users with a reinstate button", %{conn: conn} do
      {:ok, user} = Accounts.create_user(%{email: "denied@gmail.com"})
      {:ok, denied} = Accounts.deny_user(user)

      {:ok, view, html} = live(conn, "/admin/denied")

      assert html =~ "denied@gmail.com"
      assert has_element?(view, "button[phx-click='reinstate_user'][phx-value-id='#{denied.id}']")
    end

    test "shows an empty state when no users are denied", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/denied")
      assert html =~ "No denied users."
    end

    test "does not list pending or approved users", %{conn: conn} do
      {:ok, _pending} = Accounts.create_user(%{email: "pending@gmail.com"})
      {:ok, _approved} = Accounts.create_user(%{email: "member@urmc.rochester.edu"})

      {:ok, _view, html} = live(conn, "/admin/denied")

      refute html =~ "pending@gmail.com"
      refute html =~ "member@urmc.rochester.edu"
    end

    test "reinstating a denied user removes them and returns them to pending", %{conn: conn} do
      {:ok, user} = Accounts.create_user(%{email: "reinstate@gmail.com"})
      {:ok, denied} = Accounts.deny_user(user)

      {:ok, view, _html} = live(conn, "/admin/denied")

      html =
        view
        |> element("button[phx-click='reinstate_user'][phx-value-id='#{denied.id}']")
        |> render_click()

      refute html =~ "reinstate@gmail.com"
      assert Accounts.get_user!(user.id).denied == false
      assert Enum.map(Accounts.list_pending_users(), & &1.id) == [user.id]
    end
  end
end
