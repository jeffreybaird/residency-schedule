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

    test "shows no residents for an academic year with no schedule", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/calendar?date=2020-01-01")
      view |> element("button[phx-value-panel='residents']") |> render_click()
      assert render(view) =~ "No residents yet."
    end

    test "scopes the resident filter to the viewed academic year", %{conn: conn} do
      {:ok, s2026} = ResidencySchedule.Schedules.upsert_schedule(2026, "2026–2027")

      {:ok, future} =
        ResidencySchedule.Residents.insert_resident(s2026.id, %{
          position_code: "R1-9",
          residency_year: 1,
          schedule_number: 9,
          name: "FutureGradZZ"
        })

      {:ok, _} =
        ResidencySchedule.Rotations.insert_rotations(future.id, [
          %{
            slot_index: 0,
            start_date: ~D[2026-07-06],
            end_date: ~D[2026-07-12],
            rotation_type: :rei
          }
        ])

      # Viewing 2023 must not offer the 2026-only resident...
      {:ok, view_2023, _html} = live(conn, "/calendar?date=2023-07-05")
      view_2023 |> element("button[phx-value-panel='residents']") |> render_click()
      refute render(view_2023) =~ "FutureGradZZ"

      # ...but viewing 2026 must.
      {:ok, view_2026, _html} = live(conn, "/calendar?date=2026-07-08")
      view_2026 |> element("button[phx-value-panel='residents']") |> render_click()
      assert render(view_2026) =~ "FutureGradZZ"
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

    test "tour receives the resident role for a resident", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/")
      assert html =~ ~s(data-tour-role="resident")
    end

    test "tour receives the user role for a follower account" do
      {:ok, follower} =
        ResidencySchedule.Accounts.create_user(%{
          email: "partner-#{System.unique_integer()}@gmail.com"
        })

      {:ok, follower} = ResidencySchedule.Accounts.approve_user(follower)
      conn = Plug.Test.init_test_session(build_conn(), user_id: follower.id)

      {:ok, _view, html} = live(conn, "/")
      assert html =~ ~s(data-tour-role="user")
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
          name: "Briar"
        })

      {:ok, sr_2026} =
        ResidencySchedule.Residents.insert_resident(s2026.id, %{
          position_code: "R4-1",
          residency_year: 4,
          schedule_number: 1,
          name: "Briar"
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
      assert html =~ "Briar"
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

  describe "preference persistence" do
    setup %{conn: conn} do
      seed_schedule()
      {:ok, view, _html} = live(conn, "/calendar?date=2023-07-05")
      %{view: view}
    end

    test "wires the calendar for preference persistence", %{view: view} do
      assert render(view) =~ ~s(phx-hook="CalendarPrefs")
    end

    test "choosing a view pushes the saved preferences to the client", %{view: view} do
      view |> element("button[phx-value-view='month']") |> render_click()
      assert_push_event(view, "save_calendar_prefs", %{view: "month"})
    end

    test "toggling a resident records the filter in the saved preferences", %{view: view} do
      view |> element("button[phx-value-panel='residents']") |> render_click()
      id = view |> render() |> resident_filter_value()

      view |> element("button[phx-value-id='#{id}']") |> render_click()

      # Opening the panel also persists (with no residents yet), so match the
      # one-element list pushed by the toggle rather than that earlier event.
      assert_push_event(view, "save_calendar_prefs", %{residents: [resident_id]})
      assert resident_id == String.to_integer(id)
    end

    test "opening the filter panel records the open panel in the saved preferences",
         %{view: view} do
      view |> element("button[phx-value-panel='residents']") |> render_click()
      assert_push_event(view, "save_calendar_prefs", %{panel: "residents"})
    end

    test "restoring preferences applies the saved view, panel and resident filter",
         %{view: view} do
      view |> element("button[phx-value-panel='residents']") |> render_click()
      id = view |> render() |> resident_filter_value() |> String.to_integer()

      html =
        render_hook(view, "restore_prefs", %{
          "view" => "day",
          "residents" => [id],
          "panel" => "residents"
        })

      assert html =~ Calendar.strftime(~D[2023-07-05], "%A, %B %-d, %Y")
      assert html =~ "Residents (1)"
      assert has_element?(view, "button[phx-click='toggle_resident_filter']")
    end

    test "restoring an empty resident filter clears the default selection",
         %{conn: conn, user: user} do
      result = seed_schedule()
      [resident | _] = ResidencySchedule.Residents.list_residents_for_schedule(result.schedule_id)
      ResidencySchedule.Accounts.set_home_resident(user, resident.id)

      {:ok, view, html} = live(conn, "/calendar?date=2023-07-05")
      assert html =~ "Residents (1)"

      html = render_hook(view, "restore_prefs", %{"residents" => []})
      refute html =~ "Residents (1)"
    end

    test "ignores malformed preferences and keeps the current view", %{view: view} do
      html = render_hook(view, "restore_prefs", %{"view" => "bogus", "residents" => "nope"})
      assert html =~ "Jul 2 – Jul 8, 2023"
    end
  end

  # Pulls a rotation type value out of an open rotations filter panel.
  defp rotation_filter_value(html) do
    [_, type] = Regex.run(~r/phx-value-type="([^"]+)"/, html)
    type
  end

  # Pulls a resident id out of an open residents filter panel.
  defp resident_filter_value(html) do
    [_, id] = Regex.run(~r/phx-click="toggle_resident_filter"\s+phx-value-id="([^"]+)"/, html)
    id
  end
end
