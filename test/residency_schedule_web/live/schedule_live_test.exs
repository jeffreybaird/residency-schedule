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

  describe "admin session" do
    setup %{conn: conn} do
      admin_authenticate_session(%{conn: conn})
    end

    test "allows access to schedule index", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/schedule")
      assert html =~ "No schedule uploaded yet"
    end
  end

  describe "empty state" do
    test "shows upload prompt when no schedule exists", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/schedule")
      assert html =~ "No schedule uploaded yet"
    end
  end

  describe "with schedule data (R4 graduated)" do
    setup %{conn: conn} do
      # Fix date well past the 2023-2024 schedule's last rotation so R4s are gone.
      Application.put_env(:residency_schedule, :current_date, ~D[2024-07-01])
      on_exit(fn -> Application.delete_env(:residency_schedule, :current_date) end)

      seed_schedule()
      {:ok, view, html} = live(conn, "/schedule")
      %{view: view, html: html}
    end

    test "renders non-graduated residents in the grid", %{html: html} do
      assert html =~ "Carson"
    end

    test "graduated R4 cohort rendered with c/o label", %{html: html} do
      assert html =~ "Alexis"
      assert html =~ "c/o 2023"
    end

    test "R1/R2/R3/R4 year filter tabs are present", %{html: html} do
      assert html =~ "R1"
      assert html =~ "R4"
    end

    test "year filter shows only the cohort currently at R2", %{view: view} do
      html = view |> element("button[phx-value-year='2']") |> render_click()
      assert html =~ "Carson"
      refute html =~ "Kathryn"
    end

    test "All filter restores all residents", %{view: view} do
      view |> element("button[phx-value-year='2']") |> render_click()
      html = view |> element("button[phx-value-year='all']") |> render_click()
      assert html =~ "Carson"
      assert html =~ "Kathryn"
    end

    test "year group separator rows appear between classes", %{html: html} do
      assert html =~ ~s(data-year-group="2023")
      assert html =~ ~s(data-year-group="2026")
    end

    test "pill buttons use scroll_to_schedule event", %{html: html} do
      assert html =~ "scroll_to_schedule"
    end

    test "R4 filter shows cohort active in viewed year after view_academic_year event", %{
      view: view
    } do
      render_hook(view, "view_academic_year", %{"aca_year" => "2023"})
      html = view |> element("button[phx-value-year='4']") |> render_click()
      assert html =~ "Alexis"
      refute html =~ "Kathryn"
    end

    test "view_academic_year handles integer aca_year from JS hooks", %{view: view} do
      render_hook(view, "view_academic_year", %{"aca_year" => 2023})
      html = view |> element("button[phx-value-year='4']") |> render_click()
      assert html =~ "Alexis"
      refute html =~ "Kathryn"
    end
  end

  describe "with schedule data (R4 not yet graduated)" do
    setup %{conn: conn} do
      Application.put_env(:residency_schedule, :current_date, ~D[2024-01-15])
      on_exit(fn -> Application.delete_env(:residency_schedule, :current_date) end)

      seed_schedule()
      {:ok, view, html} = live(conn, "/schedule")
      %{view: view, html: html}
    end

    test "shows R4 residents when their rotations have not ended", %{html: html} do
      assert html =~ "Alexis"
      assert html =~ ~s(data-year-group="2023")
    end

    test "R4 filter shows R4 residents", %{view: view} do
      html = view |> element("button[phx-value-year='4']") |> render_click()
      assert html =~ "Alexis"
      refute html =~ "Carson"
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
      {:ok, view, html} = live(conn, "/schedule")
      %{view: view, html: html}
    end

    test "shows schedule pill for future schedule", %{html: html} do
      assert html =~ "2026"
    end

    test "incoming class is rendered with c/o label", %{html: html} do
      assert html =~ "Hannah"
      assert html =~ "c/o 2029"
    end
  end

  describe "guided tour" do
    setup %{conn: conn} do
      seed_schedule()
      {:ok, view, html} = live(conn, "/schedule")
      %{view: view, html: html}
    end

    test "tour_completed event marks tour as done", %{view: view, user: user} do
      view |> element("#guided-tour") |> render_hook("tour_completed", %{})
      updated_user = ResidencySchedule.Accounts.get_user(user.id)
      assert updated_user.tour_completed == true
    end

    test "Take a tour link is present", %{html: html} do
      assert html =~ "Take a tour"
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

  describe "current_academic_year/1" do
    test "July date returns that year" do
      assert Index.current_academic_year(~D[2026-07-01]) == 2026
    end

    test "June date returns prior year" do
      assert Index.current_academic_year(~D[2026-06-30]) == 2025
    end

    test "mid-year date returns academic year that started in prior calendar year" do
      assert Index.current_academic_year(~D[2026-04-06]) == 2025
    end
  end

  describe "build_unified_residents/3" do
    test "returns empty list for empty input" do
      assert Index.build_unified_residents([], %{}, ~D[2026-04-06]) == []
    end
  end

  describe "schedule deletion confirmed with the admin's own password" do
    setup %{conn: conn} do
      Application.put_env(:residency_schedule, :current_date, ~D[2024-07-01])
      on_exit(fn -> Application.delete_env(:residency_schedule, :current_date) end)

      seed_schedule()

      admin = create_admin("adminsecret99")
      conn = Plug.Test.init_test_session(conn, user_id: admin.id)
      {:ok, view, _html} = live(conn, "/schedule")
      %{view: view, admin: admin}
    end

    test "deletes the schedule with the admin's account password", %{view: view} do
      view |> element("button[phx-click='request_delete']") |> render_click()

      html =
        view
        |> form("form[phx-submit='delete_schedule']", %{"password" => "adminsecret99"})
        |> render_submit()

      assert html =~ "No schedule uploaded yet"
    end

    test "rejects a wrong password", %{view: view} do
      view |> element("button[phx-click='request_delete']") |> render_click()

      html =
        view
        |> form("form[phx-submit='delete_schedule']", %{"password" => "not-the-password"})
        |> render_submit()

      assert html =~ "Incorrect password."
    end
  end

  describe "schedule deletion when the admin has no password set" do
    setup %{conn: conn} do
      Application.put_env(:residency_schedule, :current_date, ~D[2024-07-01])
      on_exit(fn -> Application.delete_env(:residency_schedule, :current_date) end)

      seed_schedule()

      %{conn: conn} = admin_authenticate_session(%{conn: conn})
      {:ok, view, _html} = live(conn, "/schedule")
      %{view: view}
    end

    test "refuses deletion and points at the Admin page", %{view: view} do
      view |> element("button[phx-click='request_delete']") |> render_click()

      html =
        view
        |> form("form[phx-submit='delete_schedule']", %{"password" => "anything"})
        |> render_submit()

      assert html =~ "Set a password for your account on the Admin page first."
    end
  end
end
