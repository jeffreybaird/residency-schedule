defmodule ResidencyScheduleWeb.ActivityTypeaheadTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest
  import ResidencySchedule.ActivitySearchFixtures

  setup :authenticate_session

  setup do
    seed_activity_search()
  end

  test "search input exposes visible accessible suggestions that update with typed text", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/activities?academic_year=2026")

    assert has_element?(
             view,
             "#activities-query[role='combobox'][aria-autocomplete='list'][aria-controls='activity-suggestions'][phx-hook='ActivityTypeahead']"
           )

    view |> element("#activities-query") |> render_focus()
    assert has_element?(view, "#activities-query[aria-expanded='true']")

    assert has_element?(
             view,
             "#activity-suggestions[role='listbox'] [role='option'][data-value='GOG Continuity Clinic AM']"
           )

    view |> form("#activities-search-form", %{"query" => "CLINIC"}) |> render_change()
    assert option_values(view) == ["GOG Continuity Clinic AM", "GOG Continuity Clinic PM"]
    view |> form("#activities-search-form", %{"query" => "simulation"}) |> render_change()
    assert option_values(view) == []
    assert has_element?(view, "#activities-summary[data-total='1']")
  end

  test "choosing a task value applies the query, resets pagination and bookmarks selection", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/activities?academic_year=2026&page=2")

    view |> element("#activities-query") |> render_focus()

    view
    |> element(
      "#activity-suggestions button[role='option'][data-value='GOG Continuity Clinic PM']"
    )
    |> render_click()

    url = assert_patch(view)
    params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert params["query"] == "GOG Continuity Clinic PM"
    assert params["page"] == "1"
    assert has_element?(view, "#activities-summary[data-total='1']")
    assert has_element?(view, "#activities-query[aria-expanded='false']")
    assert_push_event(view, "activity-query-selected", %{query: "GOG Continuity Clinic PM"})
    {:ok, reopened, _} = live(conn, url)
    assert has_element?(reopened, "input[name='query'][value='GOG Continuity Clinic PM']")
    assert has_element?(reopened, "#activities-results", "GOG Continuity Clinic PM")
  end

  test "date and resident filters narrow options while invalid filters clear them", ctx do
    {:ok, view, _} = live(ctx.conn, "/activities?academic_year=2026")

    values = %{
      "query" => "clinic",
      "resident_id" => to_string(ctx.iris.resident_id),
      "start_date" => "2026-12-29",
      "end_date" => "2026-12-29"
    }

    view |> form("#activities-search-form", values) |> render_change()
    assert option_values(view) == ["GOG Continuity Clinic PM"]

    view
    |> form("#activities-search-form", %{"resident_id" => to_string(ctx.stone.resident_id)})
    |> render_change()

    assert option_values(view) == []
    render_click(view, "search", %{"resident_id" => %{}})
    assert has_element?(view, "#activities-error")
    assert option_values(view) == []
  end

  test "arrow keys select the active option and Escape closes without clearing free text", %{
    conn: conn
  } do
    {:ok, view, _} = live(conn, "/activities?academic_year=2026&query=clinic")
    render_keydown(view, "suggestion-key", %{"key" => "ArrowDown"})
    assert has_element?(view, "#activities-query[aria-expanded='true'][aria-activedescendant]")

    assert has_element?(
             view,
             "#activity-suggestions [role='option'][aria-selected='true'][data-value='GOG Continuity Clinic AM']"
           )

    render_keydown(view, "suggestion-key", %{"key" => "ArrowDown"})

    assert has_element?(
             view,
             "#activity-suggestions [aria-selected='true'][data-value='GOG Continuity Clinic PM']"
           )

    render_keydown(view, "suggestion-key", %{"key" => "ArrowUp"})

    assert has_element?(
             view,
             "#activity-suggestions [aria-selected='true'][data-value='GOG Continuity Clinic AM']"
           )

    render_keydown(view, "suggestion-key", %{"key" => "Escape"})
    assert has_element?(view, "#activities-query[aria-expanded='false'][value='clinic']")
    refute has_element?(view, "#activity-suggestions")
    render_keydown(view, "suggestion-key", %{"key" => "ArrowDown"})
    render_keydown(view, "suggestion-key", %{"key" => "Enter"})
    url = assert_patch(view)
    assert URI.decode_query(URI.parse(url).query)["query"] == "GOG Continuity Clinic AM"
    assert has_element?(view, "#activities-query[aria-expanded='false']")
  end

  test "stale or forged option labels do not replace a current free-text query", %{conn: conn} do
    {:ok, view, _} = live(conn, "/activities?academic_year=2026&query=clinic")
    view |> form("#activities-search-form", %{"query" => "simulation"}) |> render_change()
    assert_patch(view)

    for label <- ["GOG Continuity Clinic AM", "not a real task"] do
      render_click(view, "select-suggestion", %{"label" => label})
      assert has_element?(view, "#activities-query[value='simulation']")
      assert has_element?(view, "#activities-summary[data-total='1']")
      refute has_element?(view, "#activity-suggestions")
    end
  end

  defp option_values(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#activity-suggestions [role='option']")
    |> LazyHTML.attribute("data-value")
  end
end
