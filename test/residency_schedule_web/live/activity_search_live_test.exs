defmodule ResidencyScheduleWeb.ActivitySearchLiveTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest
  import ResidencySchedule.ActivitySearchFixtures
  alias ResidencySchedule.DetailedSchedules
  alias ResidencySchedule.Importer.QgendaPreview

  doctest ResidencySchedule.ActivitySearchFixtures

  setup :authenticate_session

  setup do
    seed_activity_search()
  end

  test "activities require authentication and approved users have a navigation entry", ctx do
    assert build_conn() |> get("/activities") |> redirected_to() == "/login"
    html = ctx.conn |> get("/activities") |> html_response(200)
    links = html |> LazyHTML.from_document() |> LazyHTML.query("a[href='/activities']")
    refute Enum.empty?(links)
    {:ok, view, _} = live(ctx.conn, "/activities")
    assert has_element?(view, "#activities-search-form")

    assert has_element?(
             view,
             "#activities-search-form select[name='academic_year'] option[value='2026'][selected]"
           )

    assert has_element?(view, "#activities-summary[data-total='8']")
  end

  test "task and note search shows fullname, date and literal note text with no technical metadata",
       ctx do
    {:ok, view, _} = live(ctx.conn, "/activities")
    view |> form("#activities-search-form", %{"query" => "SIMULATION KIT"}) |> render_change()
    assert has_element?(view, "#activities-summary[data-total='1']")
    assert has_element?(view, "#activities-results [data-activity-id]", "Iris Reed")
    assert has_element?(view, "#activities-results", "GOG Continuity Clinic PM")
    assert has_element?(view, "#activities-results", "2026-12-29")
    assert has_element?(view, "#activities-results", "<b>literal</b>")
    refute has_element?(view, "#activities-results b")

    for text <- [
          "QGenda",
          "Source details",
          "Page 1",
          "A15",
          "Period unspecified",
          "available for surgery"
        ] do
      refute has_element?(view, "#activities-results", text)
    end
  end

  test "filters produce bookmarkable URLs and load the same resident-date results", ctx do
    {:ok, view, _} = live(ctx.conn, "/activities")

    values = %{
      "query" => "clinic",
      "academic_year" => "2026",
      "start_date" => "2026-12-29",
      "end_date" => "2026-12-29",
      "resident_id" => to_string(ctx.iris.resident_id)
    }

    view |> form("#activities-search-form", values) |> render_change()
    url = assert_patch(view)
    params = url |> URI.parse() |> Map.fetch!(:query) |> URI.decode_query()
    assert Map.take(params, Map.keys(values)) == values
    assert has_element?(view, "#activities-summary[data-total='1']")
    {:ok, bookmarked, _} = live(ctx.conn, url)
    assert has_element?(bookmarked, "#activities-summary[data-total='1']")
    assert has_element?(bookmarked, "#activities-results", "GOG Continuity Clinic PM")
    refute has_element?(bookmarked, "#activities-results", "Juniper Vale")
  end

  test "invalid URL filters show an error and do not silently widen to all activities", ctx do
    for query <- [
          "academic_year=2026&start_date=invalid",
          "academic_year=2026&page=invalid",
          "academic_year=9999"
        ] do
      {:ok, view, _} = live(ctx.conn, "/activities?" <> query)
      assert has_element?(view, "#activities-error")
      refute has_element?(view, "#activities-results [data-activity-id]")
    end
  end

  test "pagination exposes every matching activity and a changed search resets the page", ctx do
    {:ok, preview} =
      QgendaPreview.prepare(File.read!("test/fixtures/qgenda/paginated.xlsx"),
        academic_year: 2026
      )

    {:ok, _} = DetailedSchedules.commit(preview, ctx.admin)
    {:ok, view, _} = live(ctx.conn, "/activities?academic_year=2026&query=Synthetic%20Service")
    assert has_element?(view, "#activities-summary[data-total='120']")
    assert row_count(view) == 50
    first = row_ids(view)
    view |> element("#activities-next-page") |> render_click()
    assert row_count(view) == 50
    second = row_ids(view)
    assert MapSet.disjoint?(MapSet.new(first), MapSet.new(second))
    view |> element("#activities-next-page") |> render_click()
    assert row_count(view) == 20
    assert has_element?(view, "#activities-results", "Final Synthetic Service")
    view |> form("#activities-search-form", %{"query" => "simulation kit"}) |> render_change()
    assert has_element?(view, "#activities-summary[data-total='1']")
    assert row_count(view) == 1
  end

  test "no matches is a neutral search result rather than an availability claim", ctx do
    {:ok, view, _} = live(ctx.conn, "/activities?academic_year=2026&query=no-such-task")
    assert has_element?(view, "#activities-summary[data-total='0']")
    assert has_element?(view, "#activities-results", "No activities found")
    refute has_element?(view, "#activities-results", "Available")
    refute has_element?(view, "#activities-results", "Off")
  end

  defp row_ids(view),
    do:
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#activities-results [data-activity-id]")
      |> LazyHTML.attribute("data-activity-id")

  defp row_count(view), do: view |> row_ids() |> length()
end
