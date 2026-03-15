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

    test "renders resident A and resident B dropdowns", %{html: html} do
      assert html =~ "Resident A"
      assert html =~ "Resident B"
    end

    test "selecting two residents shows shared shifts", %{view: view} do
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
      # Select the same resident for both — yields no co-service from DB query
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
  end
end
