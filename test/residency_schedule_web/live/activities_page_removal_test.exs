defmodule ResidencyScheduleWeb.ActivitiesPageRemovalTest do
  use ResidencyScheduleWeb.ConnCase
  import ResidencySchedule.QgendaDetailFixtures

  doctest ResidencySchedule.ActivitySearchFixtures

  setup :authenticate_session

  test "the Activities page is no longer routed", %{conn: conn} do
    refute Enum.any?(
             Phoenix.Router.routes(ResidencyScheduleWeb.Router),
             &(&1.path == "/activities")
           )

    assert conn |> get("/activities") |> response(404)
  end

  test "desktop and mobile navigation no longer offer Activities", %{conn: conn} do
    %{iris: iris} = seed_detail_roster()

    document =
      conn |> get("/residents/#{iris.id}") |> html_response(200) |> LazyHTML.from_document()

    assert document |> LazyHTML.query("a[href='/activities']") |> Enum.empty?()
    refute document |> LazyHTML.query("#tour-nav a[href='/']") |> Enum.empty?()
    refute document |> LazyHTML.query("#mobile-nav a[href='/']") |> Enum.empty?()
  end
end
