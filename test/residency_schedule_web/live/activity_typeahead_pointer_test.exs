defmodule ResidencyScheduleWeb.ActivityTypeaheadPointerTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest
  import ResidencySchedule.ActivitySearchFixtures

  setup :authenticate_session

  setup do
    seed_activity_search()
  end

  test "pointer selection survives the native button value added by the browser", %{conn: conn} do
    {:ok, view, _} = live(conn, "/activities?academic_year=2026&query=clinic&page=2")
    view |> element("#activities-query") |> render_focus()
    selector = "#activity-suggestions button[data-value='GOG Continuity Clinic PM']"

    native_value =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("value")
      |> List.first("")

    # Browser LiveView extractMeta always adds HTMLButtonElement.value, even
    # without a value attribute. LiveViewTest's DOM-only helper does not.
    view |> element(selector) |> render_click(%{"value" => native_value})
    url = assert_patch(view)
    params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert params["query"] == "GOG Continuity Clinic PM"
    assert params["page"] == "1"
    assert has_element?(view, "#activities-summary[data-total='1']")
    assert has_element?(view, "#activities-query[aria-expanded='false']")
    assert_push_event(view, "activity-query-selected", %{query: "GOG Continuity Clinic PM"})
  end
end
