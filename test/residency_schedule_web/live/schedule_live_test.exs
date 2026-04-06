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

    test "schedule label appears in section headers", %{html: html} do
      assert html =~ "2023–2024"
    end

    test "pill buttons use scroll_to_schedule event", %{html: html} do
      assert html =~ "scroll_to_schedule"
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
end
