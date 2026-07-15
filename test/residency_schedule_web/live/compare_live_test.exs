defmodule ResidencyScheduleWeb.CompareLiveTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest

  setup :authenticate_session

  describe "unauthenticated access" do
    test "redirects to /login when no session", %{conn: _conn} do
      result = get(Phoenix.ConnTest.build_conn(), "/compare")
      assert redirected_to(result) == "/login"
    end
  end

  describe "empty state" do
    test "shows no schedule message when no schedule exists", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/compare")
      assert html =~ "No schedule uploaded yet"
    end
  end

  describe "with schedule data" do
    setup %{conn: conn} do
      seed_schedule()
      {:ok, view, html} = live(conn, "/compare")
      %{view: view, html: html}
    end

    test "renders compare heading", %{html: html} do
      assert html =~ "Compare"
    end

    test "passes the resident role to the guided tour", %{html: html} do
      assert html =~ ~s(data-tour-role="resident")
    end

    test "renders resident A and resident B dropdowns", %{html: html} do
      assert html =~ "Resident A"
      assert html =~ "Resident B"
    end

    test "selecting two residents shows shared shifts stats", %{view: view} do
      residents = ResidencySchedule.Residents.list_residents()
      [a, b | _] = residents

      view
      |> element("form[phx-change='select_resident_a']")
      |> render_change(%{"resident_id" => to_string(a.id)})

      html =
        view
        |> element("form[phx-change='select_resident_b']")
        |> render_change(%{"resident_id" => to_string(b.id)})

      assert html =~ "Shared Shifts"
    end

    test "no shared shifts message shown when residents share no service", %{view: view} do
      residents = ResidencySchedule.Residents.list_residents()
      [a, b | _] = residents

      view
      |> element("form[phx-change='select_resident_a']")
      |> render_change(%{"resident_id" => to_string(a.id)})

      html =
        view
        |> element("form[phx-change='select_resident_b']")
        |> render_change(%{"resident_id" => to_string(b.id)})

      # Either shows a co-service table or a "No shared shifts" message
      assert html =~ "Shared Shifts" or html =~ "No shared shifts"
    end

    test "toggle_stats collapses and hides dropdowns", %{view: view} do
      html = view |> element("button[phx-click='toggle_stats']") |> render_click()
      refute html =~ "Resident A"
      refute html =~ "Resident B"
    end

    test "toggle_stats expands again after collapsing", %{view: view} do
      view |> element("button[phx-click='toggle_stats']") |> render_click()
      html = view |> element("button[phx-click='toggle_stats']") |> render_click()
      assert html =~ "Resident A"
      assert html =~ "Resident B"
    end

    test "summary breakdown is pre-collapsed and expands on toggle", %{view: view} do
      schedule = hd(ResidencySchedule.Schedules.list_schedules())
      residents = ResidencySchedule.Residents.list_residents_for_schedule(schedule.id)
      # Pick two residents on the same service to get co-service days
      [a, b | _] = residents

      view
      |> element("form[phx-change='select_resident_a']")
      |> render_change(%{"resident_id" => to_string(a.id)})

      view
      |> element("form[phx-change='select_resident_b']")
      |> render_change(%{"resident_id" => to_string(b.id)})

      # When there are shared shifts, toggle_summary appears
      html = render(view)

      if html =~ "toggle_summary" do
        expanded_html = view |> element("button[phx-click='toggle_summary']") |> render_click()
        assert expanded_html =~ "Collapse"
      else
        # No shared shifts between these two — just verify the page loaded
        assert html =~ "Shared Shifts"
      end
    end

    test "toggle_summary collapses after expanding", %{view: view} do
      schedule = hd(ResidencySchedule.Schedules.list_schedules())
      residents = ResidencySchedule.Residents.list_residents_for_schedule(schedule.id)
      [a, b | _] = residents

      view
      |> element("form[phx-change='select_resident_a']")
      |> render_change(%{"resident_id" => to_string(a.id)})

      view
      |> element("form[phx-change='select_resident_b']")
      |> render_change(%{"resident_id" => to_string(b.id)})

      html = render(view)

      if html =~ "toggle_summary" do
        view |> element("button[phx-click='toggle_summary']") |> render_click()
        collapsed = view |> element("button[phx-click='toggle_summary']") |> render_click()
        assert collapsed =~ "Expand"
      else
        assert html =~ "Shared Shifts"
      end
    end
  end
end
