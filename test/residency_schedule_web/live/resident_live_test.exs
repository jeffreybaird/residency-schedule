defmodule ResidencyScheduleWeb.ResidentLiveTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest

  setup :authenticate_session

  describe "unauthenticated access" do
    test "redirects to /login when no session", %{conn: _conn} do
      result = get(Phoenix.ConnTest.build_conn(), "/residents/1")
      assert redirected_to(result) == "/login"
    end
  end

  describe "resident page" do
    setup %{conn: conn} do
      %{schedule_id: _sid} = seed_schedule()
      resident = ResidencySchedule.Residents.get_resident_by_position!("R4-1")
      {:ok, view, html} = live(conn, "/residents/#{resident.id}")
      %{view: view, html: html, resident: resident}
    end

    test "renders resident name", %{html: html, resident: resident} do
      assert html =~ resident.name
    end

    test "renders position code", %{html: html, resident: resident} do
      assert html =~ resident.position_code
    end

    test "shows Set as My Resident button when no home resident set", %{html: html} do
      assert html =~ "Set as My Resident"
    end

    test "shows My Resident badge when resident is home resident", %{conn: conn} do
      resident = ResidencySchedule.Residents.get_resident_by_position!("R4-1")

      conn =
        conn
        |> Plug.Test.init_test_session(authenticated: true, resident_id: resident.id)

      {:ok, _view, html} = live(conn, "/residents/#{resident.id}")
      assert html =~ "My Resident"
    end
  end
end
