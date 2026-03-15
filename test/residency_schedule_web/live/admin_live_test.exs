defmodule ResidencyScheduleWeb.AdminLiveTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest

  describe "unauthenticated access" do
    test "redirects to /admin/login when no admin session", %{conn: conn} do
      conn = get(conn, "/admin")
      assert redirected_to(conn) == "/admin/login"
    end
  end

  describe "admin page without schedules" do
    setup %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, authenticated: true, admin: true)
      {:ok, view, html} = live(conn, "/admin")
      %{conn: conn, view: view, html: html}
    end

    test "renders Admin heading", %{html: html} do
      assert html =~ "Admin"
    end

    test "renders Upload CSV link", %{html: html} do
      assert html =~ "Upload CSV"
    end

    test "renders link to /admin/upload", %{html: html} do
      assert html =~ "/admin/upload"
    end

    test "does not show delete section when no schedules", %{html: html} do
      refute html =~ "Delete a Schedule"
    end
  end

  describe "admin page with schedules" do
    setup %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, authenticated: true, admin: true)
      seed_schedule()
      {:ok, view, html} = live(conn, "/admin")
      %{conn: conn, view: view, html: html}
    end

    test "shows schedule count", %{html: html} do
      assert html =~ "1 schedule"
    end

    test "shows schedule label", %{html: html} do
      assert html =~ "2023"
    end

    test "shows Delete button for each schedule", %{html: html} do
      assert html =~ "Delete"
    end

    test "request_delete shows confirmation UI", %{view: view} do
      schedule = List.first(ResidencySchedule.Schedules.list_schedules())
      html = view |> element("button[phx-value-id='#{schedule.id}']") |> render_click()
      assert html =~ "Confirm"
      assert html =~ "Cancel"
    end

    test "cancel_delete hides confirmation UI", %{view: view} do
      schedule = List.first(ResidencySchedule.Schedules.list_schedules())
      view |> element("button[phx-value-id='#{schedule.id}']") |> render_click()
      html = view |> element("button[phx-click='cancel_delete']") |> render_click()
      refute html =~ "Confirm"
    end

    test "confirm_delete removes the schedule", %{view: view} do
      schedule = List.first(ResidencySchedule.Schedules.list_schedules())
      view |> element("button[phx-value-id='#{schedule.id}']") |> render_click()
      html = view |> element("button[phx-click='confirm_delete']") |> render_click()
      refute html =~ "Delete a Schedule"
    end
  end
end
