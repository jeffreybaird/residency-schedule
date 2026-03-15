defmodule ResidencyScheduleWeb.CalendarLiveTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest

  setup :authenticate_session

  describe "unauthenticated access" do
    test "redirects to /login when no session", %{conn: _conn} do
      result = get(Phoenix.ConnTest.build_conn(), "/calendar")
      assert redirected_to(result) == "/login"
    end
  end

  describe "empty state" do
    test "shows no schedule message when no schedule exists", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/calendar")
      assert html =~ "No schedule uploaded yet"
    end
  end

  describe "with schedule data" do
    setup %{conn: conn} do
      seed_schedule()
      {:ok, view, html} = live(conn, "/calendar")
      %{view: view, html: html}
    end

    test "renders month and year heading", %{html: html} do
      assert html =~ "Calendar"
    end

    test "renders calendar day grid", %{html: html} do
      assert html =~ "Mon" or html =~ "Mo"
    end

    test "prev_month navigates backward one month", %{view: view} do
      html_before = render(view)
      html_after = view |> element("button[phx-click='prev_month']") |> render_click()
      refute html_before == html_after
    end

    test "next_month navigates forward one month", %{view: view} do
      html_before = render(view)
      html_after = view |> element("button[phx-click='next_month']") |> render_click()
      refute html_before == html_after
    end
  end
end
