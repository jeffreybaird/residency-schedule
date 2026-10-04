defmodule ResidencyScheduleWeb.ActivitySearchInvalidEventTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest
  import ResidencySchedule.ActivitySearchFixtures

  setup :authenticate_session

  setup do
    seed_activity_search()
  end

  test "malformed search and pagination events clear results instead of widening the query", %{
    conn: conn
  } do
    for {event, params} <- [{"search", %{"resident_id" => %{}}}, {"paginate", %{"page" => %{}}}] do
      {:ok, view, _} = live(conn, "/activities?academic_year=2026&query=simulation")
      assert has_element?(view, "#activities-summary[data-total='1']")
      render_click(view, event, params)
      assert has_element?(view, "#activities-error")
      refute has_element?(view, "#activities-results [data-activity-id]")
    end
  end
end
