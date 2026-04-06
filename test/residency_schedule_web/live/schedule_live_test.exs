defmodule ResidencyScheduleWeb.ScheduleLiveTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest

  alias ResidencyScheduleWeb.ScheduleLive.Index

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

  describe "with schedule data (R4 graduated)" do
    setup %{conn: conn} do
      # Fix date well past the 2023-2024 schedule's last rotation so R4s are gone.
      Application.put_env(:residency_schedule, :current_date, ~D[2024-07-01])
      on_exit(fn -> Application.delete_env(:residency_schedule, :current_date) end)

      seed_schedule()
      {:ok, view, html} = live(conn, "/")
      %{view: view, html: html}
    end

    test "renders non-graduated residents in the grid", %{html: html} do
      assert html =~ "R1-1"
    end

    test "hides graduated R4 residents whose last rotation has ended", %{html: html} do
      refute html =~ "Alexis"
    end

    test "R1/R2/R3/R4 year filter tabs are present", %{html: html} do
      assert html =~ "R1"
      assert html =~ "R4"
    end

    test "year filter shows only R1 residents when R1 selected", %{view: view} do
      html = view |> element("button[phx-value-year='1']") |> render_click()
      assert html =~ "R1-1"
      refute html =~ "R3-1"
    end

    test "All filter restores all residents", %{view: view} do
      view |> element("button[phx-value-year='1']") |> render_click()
      html = view |> element("button[phx-value-year='all']") |> render_click()
      assert html =~ "R1-1"
      assert html =~ "R3-1"
    end

    test "no year group headers in the grid", %{html: html} do
      refute html =~ "R1 Residents"
      refute html =~ "R4 Residents"
    end

    test "pill buttons use scroll_to_schedule event", %{html: html} do
      assert html =~ "scroll_to_schedule"
    end
  end

  describe "with schedule data (R4 not yet graduated)" do
    setup %{conn: conn} do
      Application.put_env(:residency_schedule, :current_date, ~D[2024-01-15])
      on_exit(fn -> Application.delete_env(:residency_schedule, :current_date) end)

      seed_schedule()
      {:ok, view, html} = live(conn, "/")
      %{view: view, html: html}
    end

    test "shows R4 residents when their rotations have not ended", %{html: html} do
      assert html =~ "Alexis"
      assert html =~ "R4-1"
    end

    test "R4 filter shows R4 residents", %{view: view} do
      html = view |> element("button[phx-value-year='4']") |> render_click()
      assert html =~ "R4-1"
      refute html =~ "R1-1"
    end
  end

  describe "future schedules are included" do
    setup %{conn: conn} do
      # April 2026: the 2026-2027 schedule starts in ~July but should still
      # show columns and new R1 rows (with blank cells until July).
      Application.put_env(:residency_schedule, :current_date, ~D[2026-04-06])
      on_exit(fn -> Application.delete_env(:residency_schedule, :current_date) end)

      seed_schedule()
      seed_schedule(2026)
      {:ok, view, html} = live(conn, "/")
      %{view: view, html: html}
    end

    test "shows schedule pill for future schedule", %{html: html} do
      assert html =~ "2026"
    end
  end

  describe "build_combined_slots/1" do
    test "combines slots from multiple sections in order" do
      sections = [
        %{
          schedule: %{id: 1},
          slots: [
            {0, ~D[2023-07-03], ~D[2023-07-09]},
            {1, ~D[2023-07-10], ~D[2023-07-16]}
          ]
        },
        %{
          schedule: %{id: 2},
          slots: [
            {0, ~D[2024-07-01], ~D[2024-07-07]},
            {1, ~D[2024-07-08], ~D[2024-07-14]}
          ]
        }
      ]

      result = Index.build_combined_slots(sections)

      assert length(result) == 4
      assert Enum.at(result, 0) == {1, 0, ~D[2023-07-03], ~D[2023-07-09], true}
      assert Enum.at(result, 1) == {1, 1, ~D[2023-07-10], ~D[2023-07-16], false}
      assert Enum.at(result, 2) == {2, 0, ~D[2024-07-01], ~D[2024-07-07], true}
      assert Enum.at(result, 3) == {2, 1, ~D[2024-07-08], ~D[2024-07-14], false}
    end

    test "returns empty list for empty sections" do
      assert Index.build_combined_slots([]) == []
    end
  end

  describe "slot_header_label/2" do
    test "same month shows day range and month" do
      assert Index.slot_header_label(~D[2023-07-03], ~D[2023-07-09]) == "3–9 Jul"
    end

    test "cross-month shows both months" do
      label = Index.slot_header_label(~D[2023-06-28], ~D[2023-07-04])
      assert label =~ "Jun"
      assert label =~ "Jul"
    end
  end

  describe "cell_groups_unified/2" do
    test "groups contiguous same-type rotations" do
      all_slots = [
        {1, 0, ~D[2023-07-03], ~D[2023-07-09], true},
        {1, 1, ~D[2023-07-10], ~D[2023-07-16], false}
      ]

      lookup = %{
        {1, 0} => %{rotation_type: "strong_obstetrics", end_date: ~D[2023-07-09]},
        {1, 1} => %{rotation_type: "strong_obstetrics", end_date: ~D[2023-07-16]}
      }

      result = Index.cell_groups_unified(all_slots, lookup)
      assert [{2, %{rotation_type: "strong_obstetrics"}}] = result
    end

    test "handles empty lookup — all slots become blank" do
      all_slots = [{1, 0, ~D[2023-07-03], ~D[2023-07-09], true}]
      result = Index.cell_groups_unified(all_slots, %{})
      assert [{1, nil}] = result
    end
  end

  describe "graduated?/2" do
    test "R4 whose last rotation has ended is graduated" do
      resident = %{current_year: 4, last_rotation_end: ~D[2024-06-15]}
      assert Index.graduated?(resident, ~D[2025-07-01])
    end

    test "R4 with remaining rotations is not graduated" do
      resident = %{current_year: 4, last_rotation_end: ~D[2026-06-20]}
      refute Index.graduated?(resident, ~D[2026-04-06])
    end

    test "R4 whose last rotation ends today is not graduated" do
      resident = %{current_year: 4, last_rotation_end: ~D[2025-06-20]}
      refute Index.graduated?(resident, ~D[2025-06-20])
    end

    test "non-R4 is never graduated even with past rotations" do
      resident = %{current_year: 3, last_rotation_end: ~D[2020-06-15]}
      refute Index.graduated?(resident, ~D[2025-07-01])
    end

    test "R4 with no rotations is not graduated" do
      resident = %{current_year: 4, last_rotation_end: nil}
      refute Index.graduated?(resident, ~D[2025-07-01])
    end

    test "R1 with no rotations is not graduated" do
      resident = %{current_year: 1, last_rotation_end: nil}
      refute Index.graduated?(resident, ~D[2025-07-01])
    end
  end

  describe "build_unified_residents/3" do
    test "returns empty list for empty input" do
      assert Index.build_unified_residents([], %{}, ~D[2026-04-06]) == []
    end
  end
end
