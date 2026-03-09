defmodule ResidencyScheduleWeb.ScheduleLiveTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest

  setup :authenticate_session

  describe "unauthenticated access" do
    test "redirects to /login when no session", %{conn: _conn} do
      fresh_conn = Phoenix.ConnTest.build_conn()
      conn = get(fresh_conn, "/")
      assert redirected_to(conn) == "/login"
    end
  end

  describe "empty state" do
    test "shows upload prompt when no schedule exists", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "No schedule uploaded yet"
    end
  end

  describe "with schedule data" do
    setup %{conn: conn} do
      seed_schedule()
      {:ok, view, html} = live(conn, "/")
      %{view: view, html: html}
    end

    test "renders R4 residents in the Gantt grid", %{html: html} do
      assert html =~ "R4-1"
      assert html =~ "Alexis"
    end

    test "R1/R2/R3/R4 year filter tabs are present", %{html: html} do
      assert html =~ "R1"
      assert html =~ "R4"
    end

    test "year filter shows only R4 residents when R4 selected", %{view: view} do
      html = view |> element("button[phx-value-year='4']") |> render_click()
      assert html =~ "R4-1"
      refute html =~ "R1-1"
    end

    test "All filter restores all residents", %{view: view} do
      view |> element("button[phx-value-year='4']") |> render_click()
      html = view |> element("button[phx-value-year='all']") |> render_click()
      assert html =~ "R4-1"
    end
  end
end
