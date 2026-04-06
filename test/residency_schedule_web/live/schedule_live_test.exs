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
      # Fix date to July 2024 so R4 from the 2023-2024 schedule are graduated
      # but R1-R3 are still visible. This makes the test deterministic.
      Application.put_env(:residency_schedule, :current_date, ~D[2024-07-01])
      on_exit(fn -> Application.delete_env(:residency_schedule, :current_date) end)

      seed_schedule()
      {:ok, view, html} = live(conn, "/")
      %{view: view, html: html}
    end

    test "renders non-graduated residents in the Gantt grid", %{html: html} do
      # R1 residents from 2023-2024 are not graduated — still shown
      assert html =~ "R1-1"
    end

    test "hides graduated R4 residents from completed academic year", %{html: html} do
      # R4 from 2023-2024 graduated (June 30, 2024 is past) — hidden
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

    test "year group headers show R-year labels", %{html: html} do
      assert html =~ "R1 Residents"
    end

    test "pill buttons use scroll_to_schedule event", %{html: html} do
      assert html =~ "scroll_to_schedule"
    end
  end

  describe "with schedule data (R4 not yet graduated)" do
    setup %{conn: conn} do
      # Fix date to mid-year so R4 residents are still active
      Application.put_env(:residency_schedule, :current_date, ~D[2024-01-15])
      on_exit(fn -> Application.delete_env(:residency_schedule, :current_date) end)

      seed_schedule()
      {:ok, view, html} = live(conn, "/")
      %{view: view, html: html}
    end

    test "shows R4 residents when academic year has not ended", %{html: html} do
      assert html =~ "Alexis"
      assert html =~ "R4-1"
    end

    test "R4 filter shows R4 residents", %{view: view} do
      html = view |> element("button[phx-value-year='4']") |> render_click()
      assert html =~ "R4-1"
      refute html =~ "R1-1"
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

    test "marks first slot in each schedule section" do
      sections = [
        %{schedule: %{id: 10}, slots: [{0, ~D[2023-07-03], ~D[2023-07-09]}]},
        %{schedule: %{id: 20}, slots: [{0, ~D[2024-07-01], ~D[2024-07-07]}]}
      ]

      result = Index.build_combined_slots(sections)
      assert Enum.all?(result, fn {_, _, _, _, first?} -> first? end)
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

  describe "cell_groups/2" do
    test "groups contiguous same-type rotations" do
      slots = [{0, ~D[2023-07-03], ~D[2023-07-09]}, {1, ~D[2023-07-10], ~D[2023-07-16]}]

      rotations = [
        %{slot_index: 0, rotation_type: "strong_obstetrics", end_date: ~D[2023-07-09]},
        %{slot_index: 1, rotation_type: "strong_obstetrics", end_date: ~D[2023-07-16]}
      ]

      result = Index.cell_groups(slots, rotations)
      assert [{2, %{rotation_type: "strong_obstetrics"}}] = result
    end

    test "splits different rotation types into separate groups" do
      slots = [{0, ~D[2023-07-03], ~D[2023-07-09]}, {1, ~D[2023-07-10], ~D[2023-07-16]}]

      rotations = [
        %{slot_index: 0, rotation_type: "strong_obstetrics", end_date: ~D[2023-07-09]},
        %{slot_index: 1, rotation_type: "float", end_date: ~D[2023-07-16]}
      ]

      result = Index.cell_groups(slots, rotations)
      assert [{1, %{rotation_type: "strong_obstetrics"}}, {1, %{rotation_type: "float"}}] = result
    end

    test "handles empty rotation list" do
      slots = [{0, ~D[2023-07-03], ~D[2023-07-09]}]
      result = Index.cell_groups(slots, [])
      assert [{1, nil}] = result
    end
  end

  describe "cell_groups_unified/2" do
    test "groups contiguous same-type rotations across schedule slots" do
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

    test "splits different rotation types" do
      all_slots = [
        {1, 0, ~D[2023-07-03], ~D[2023-07-09], true},
        {1, 1, ~D[2023-07-10], ~D[2023-07-16], false}
      ]

      lookup = %{
        {1, 0} => %{rotation_type: "strong_obstetrics", end_date: ~D[2023-07-09]},
        {1, 1} => %{rotation_type: "float", end_date: ~D[2023-07-16]}
      }

      result = Index.cell_groups_unified(all_slots, lookup)

      assert [
               {1, %{rotation_type: "strong_obstetrics"}},
               {1, %{rotation_type: "float"}}
             ] = result
    end

    test "handles empty lookup — all slots become blank" do
      all_slots = [{1, 0, ~D[2023-07-03], ~D[2023-07-09], true}]
      result = Index.cell_groups_unified(all_slots, %{})
      assert [{1, nil}] = result
    end

    test "spans across schedules with gap in between" do
      all_slots = [
        {1, 0, ~D[2023-07-03], ~D[2023-07-09], true},
        {2, 0, ~D[2024-07-01], ~D[2024-07-07], true}
      ]

      lookup = %{
        {1, 0} => %{rotation_type: "float", end_date: ~D[2023-07-09]},
        {2, 0} => %{rotation_type: "strong_obstetrics", end_date: ~D[2024-07-07]}
      }

      result = Index.cell_groups_unified(all_slots, lookup)

      assert [
               {1, %{rotation_type: "float"}},
               {1, %{rotation_type: "strong_obstetrics"}}
             ] = result
    end
  end

  describe "graduated?/3" do
    test "R4 in a completed academic year is graduated" do
      resident = %{current_year: 4, latest_schedule_id: 1}
      schedule_map = %{1 => %{academic_year: 2023}}
      assert Index.graduated?(resident, schedule_map, ~D[2025-07-01])
    end

    test "R4 in current academic year is not graduated" do
      resident = %{current_year: 4, latest_schedule_id: 1}
      schedule_map = %{1 => %{academic_year: 2025}}
      refute Index.graduated?(resident, schedule_map, ~D[2025-07-01])
    end

    test "R4 exactly on June 30 end date is not graduated" do
      resident = %{current_year: 4, latest_schedule_id: 1}
      schedule_map = %{1 => %{academic_year: 2024}}
      # June 30, 2025 is the end date — on that date, not yet past
      refute Index.graduated?(resident, schedule_map, ~D[2025-06-30])
    end

    test "R4 on July 1 after end date is graduated" do
      resident = %{current_year: 4, latest_schedule_id: 1}
      schedule_map = %{1 => %{academic_year: 2024}}
      assert Index.graduated?(resident, schedule_map, ~D[2025-07-01])
    end

    test "non-R4 resident is never graduated regardless of schedule age" do
      resident = %{current_year: 3, latest_schedule_id: 1}
      schedule_map = %{1 => %{academic_year: 2020}}
      refute Index.graduated?(resident, schedule_map, ~D[2025-07-01])
    end

    test "R1 in old schedule is not graduated" do
      resident = %{current_year: 1, latest_schedule_id: 1}
      schedule_map = %{1 => %{academic_year: 2020}}
      refute Index.graduated?(resident, schedule_map, ~D[2025-07-01])
    end
  end

  describe "build_unified_residents/3" do
    test "returns empty list for empty input" do
      assert Index.build_unified_residents([], %{}, ~D[2026-04-06]) == []
    end
  end
end
