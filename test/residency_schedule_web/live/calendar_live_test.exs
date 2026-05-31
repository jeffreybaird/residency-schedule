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

    test "renders the calendar heading", %{html: html} do
      assert html =~ "Calendar"
    end

    test "renders the month day grid", %{html: html} do
      assert html =~ "Mon" or html =~ "Mo"
    end

    test "wires the calendar body for swipe navigation", %{html: html} do
      assert html =~ ~s(phx-hook="CalendarSwipe")
    end

    test "prev navigates backward and changes the period label", %{view: view} do
      html_before = render(view)
      html_after = view |> element("button[phx-click='prev']") |> render_click()
      refute html_before == html_after
    end

    test "next navigates forward and changes the period label", %{view: view} do
      html_before = render(view)
      html_after = view |> element("button[phx-click='next']") |> render_click()
      refute html_before == html_after
    end

    test "today returns to the current period", %{view: view} do
      view |> element("button[phx-value-view='month']") |> render_click()
      view |> element("button[phx-click='prev']") |> render_click()
      html = view |> element("button[phx-click='today']") |> render_click()
      assert html =~ Calendar.strftime(Date.utc_today(), "%B %Y")
    end
  end

  describe "view modes" do
    setup %{conn: conn} do
      seed_schedule()
      {:ok, view, _html} = live(conn, "/calendar?date=2023-07-05")
      %{view: view}
    end

    test "defaults to week view", %{view: view} do
      # Week label spans a Sun–Sat range, e.g. "Jul 2 – Jul 8, 2023"
      assert render(view) =~ "Jul 2 – Jul 8, 2023"
    end

    test "switches to month view", %{view: view} do
      html = view |> element("button[phx-value-view='month']") |> render_click()
      assert html =~ "July 2023"
    end

    test "switches to day view and lists rotations for the focused day", %{view: view} do
      html = view |> element("button[phx-value-view='day']") |> render_click()
      assert html =~ Calendar.strftime(~D[2023-07-05], "%A, %B %-d, %Y")
      refute html =~ "No rotations recorded for this day."
    end

    test "week navigation shifts by seven days", %{view: view} do
      view |> element("button[phx-value-view='week']") |> render_click()
      html = view |> element("button[phx-click='next']") |> render_click()
      assert html =~ "Jul 9 – Jul 15, 2023"
    end

    test "day navigation shifts by one day", %{view: view} do
      view |> element("button[phx-value-view='day']") |> render_click()
      html = view |> element("button[phx-click='next']") |> render_click()
      assert html =~ Calendar.strftime(~D[2023-07-06], "%A, %B %-d, %Y")
    end
  end

  describe "deep links" do
    setup do
      seed_schedule()
      :ok
    end

    test "date param sets the focused period", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/calendar?date=2023-08-01&view=month")
      assert html =~ "August 2023"
    end

    test "view param selects the initial view mode", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/calendar?date=2023-07-05&view=day")
      assert html =~ Calendar.strftime(~D[2023-07-05], "%A, %B %-d, %Y")
    end

    test "invalid date param falls back to today", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/calendar?date=not-a-date&view=month")
      assert html =~ Calendar.strftime(Date.utc_today(), "%B %Y")
    end
  end

  describe "filters" do
    setup %{conn: conn} do
      seed_schedule()
      {:ok, view, _html} = live(conn, "/calendar?date=2023-07-05")
      %{view: view}
    end

    test "residents panel lists residents in view", %{view: view} do
      view |> element("button[phx-value-panel='residents']") |> render_click()
      assert has_element?(view, "button[phx-click='toggle_resident_filter']")
    end

    test "rotations panel lists rotation types in view", %{view: view} do
      view |> element("button[phx-value-panel='rotations']") |> render_click()
      assert has_element?(view, "button[phx-click='toggle_rotation_filter']")
    end

    test "toggling the panel again closes it", %{view: view} do
      view |> element("button[phx-value-panel='residents']") |> render_click()
      assert has_element?(view, "button[phx-click='toggle_resident_filter']")
      view |> element("button[phx-value-panel='residents']") |> render_click()
      refute has_element?(view, "button[phx-click='toggle_resident_filter']")
    end

    test "selecting a rotation type filters the day view to that type", %{view: view} do
      view |> element("button[phx-value-view='day']") |> render_click()
      view |> element("button[phx-value-panel='rotations']") |> render_click()

      # Grab the first available rotation type and filter to it.
      type =
        view
        |> render()
        |> rotation_filter_value()

      view |> element("button[phx-value-type='#{type}']") |> render_click()
      html = render(view)

      assert html =~ "(1)"
      refute html =~ "No rotations recorded for this day."
    end

    test "clearing the rotation filter restores all types", %{view: view} do
      view |> element("button[phx-value-panel='rotations']") |> render_click()
      type = view |> render() |> rotation_filter_value()
      view |> element("button[phx-value-type='#{type}']") |> render_click()
      assert render(view) =~ "Rotations (1)"

      html = view |> element("button[phx-click='clear_rotation_filter']") |> render_click()
      refute html =~ "Rotations (1)"
    end

    test "empty period shows no residents in view", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/calendar?date=2020-01-01")
      view |> element("button[phx-value-panel='residents']") |> render_click()
      assert render(view) =~ "No residents in view."
    end
  end

  describe "home page" do
    test "/ renders the calendar with the tour link", %{conn: conn} do
      seed_schedule()
      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Calendar"
      assert html =~ "Take a tour"
    end

    test "defaults to the week view", %{conn: conn} do
      seed_schedule()
      {:ok, _view, html} = live(conn, "/?date=2023-07-05")
      assert html =~ "Jul 2 – Jul 8, 2023"
    end

    test "new user sees the tour auto-start attribute", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ ~s(data-auto-start="true")
    end

    test "returning user with a completed tour does not auto-start", %{conn: conn, user: user} do
      ResidencySchedule.Accounts.complete_tour(user)
      {:ok, _view, html} = live(conn, "/")
      assert html =~ ~s(data-auto-start="false")
    end

    test "pre-filters to the user's assigned resident", %{conn: conn, user: user} do
      result = seed_schedule()
      [resident | _] = ResidencySchedule.Residents.list_residents_for_schedule(result.schedule_id)
      ResidencySchedule.Accounts.set_home_resident(user, resident.id)

      {:ok, _view, html} = live(conn, "/")
      assert html =~ "Residents (1)"
    end

    test "keeps showing the assigned resident after navigating into the next schedule",
         %{conn: conn, user: user} do
      {:ok, s2023} = ResidencySchedule.Schedules.upsert_schedule(2023, "2023–2024")
      {:ok, s2026} = ResidencySchedule.Schedules.upsert_schedule(2026, "2026–2027")

      {:ok, sr_2023} =
        ResidencySchedule.Residents.insert_resident(s2023.id, %{
          position_code: "R3-1",
          residency_year: 3,
          schedule_number: 1,
          name: "Alexis"
        })

      {:ok, sr_2026} =
        ResidencySchedule.Residents.insert_resident(s2026.id, %{
          position_code: "R4-1",
          residency_year: 4,
          schedule_number: 1,
          name: "Alexis"
        })

      {:ok, _} =
        ResidencySchedule.Rotations.insert_rotations(sr_2026.id, [
          %{
            slot_index: 0,
            start_date: ~D[2026-07-06],
            end_date: ~D[2026-07-12],
            rotation_type: :oncology
          }
        ])

      # Home is pinned to the 2023 record; the 2026 view must still show them.
      ResidencySchedule.Accounts.set_home_resident(user, sr_2023.id)

      {:ok, _view, html} = live(conn, "/?date=2026-07-08&view=day")
      assert html =~ "Alexis"
      # The resident is one entity, so the filter counts them once across years.
      assert html =~ "Residents (1)"
    end

    test "shows everyone when the user has no assigned resident", %{conn: conn} do
      seed_schedule()
      {:ok, _view, html} = live(conn, "/")
      refute html =~ "Residents ("
    end
  end

  describe "day modal" do
    setup %{conn: conn} do
      seed_schedule()
      {:ok, view, _html} = live(conn, "/calendar?date=2023-07-05")
      %{view: view}
    end

    test "selecting a day opens the detail modal", %{view: view} do
      html =
        view
        |> element("div[phx-click='select_day'][phx-value-date='2023-07-05']")
        |> render_click()

      assert html =~ Calendar.strftime(~D[2023-07-05], "%A, %B %-d, %Y")
      assert has_element?(view, "button[phx-click='open_day_view']")
    end

    test "modal day-view link switches to day view", %{view: view} do
      view
      |> element("div[phx-click='select_day'][phx-value-date='2023-07-05']")
      |> render_click()

      html = view |> element("button[phx-click='open_day_view']") |> render_click()
      assert html =~ Calendar.strftime(~D[2023-07-05], "%A, %B %-d, %Y")
      refute has_element?(view, "div[phx-click='close_modal']")
    end
  end

  # Pulls a rotation type value out of an open rotations filter panel.
  defp rotation_filter_value(html) do
    [_, type] = Regex.run(~r/phx-value-type="([^"]+)"/, html)
    type
  end
end
