defmodule ResidencyScheduleWeb.RotationSupportLiveTest do
  use ResidencyScheduleWeb.ConnCase

  import Phoenix.LiveViewTest

  alias ResidencySchedule.Importer.ScheduleImporter
  alias ResidencySchedule.Residents
  alias ResidencySchedule.RotationSupportFixtures, as: Fixtures

  setup :admin_authenticate_session

  test "editor shows schedule abbreviations and offers every supported rotation", %{conn: conn} do
    assert {:ok, result, []} =
             ScheduleImporter.import_csv(Fixtures.csv(Enum.map(Fixtures.pairs(), &elem(&1, 0))))

    [resident] = Residents.list_residents_for_schedule(result.schedule_id)

    rotations =
      Residents.get_resident!(resident.id).rotations |> Enum.sort_by(& &1.start_date, Date)

    {:ok, view, _} = live(conn, "/admin/edit")

    view
    |> form("form[phx-submit='load_schedule']", %{"schedule_id" => to_string(result.schedule_id)})
    |> render_submit()

    for {{label, _}, rotation} <- Enum.zip(Fixtures.pairs(), rotations) do
      assert has_element?(
               view,
               "#editor-grid [data-rotation-id='#{rotation.id}'] button[phx-click='edit_assignment']",
               label
             )
    end

    view
    |> element("[phx-click='edit_assignment'][phx-value-id='#{hd(rotations).id}']")
    |> render_click()

    for {_, type} <- Fixtures.pairs() do
      assert has_element?(view, "#assignment-form select option[value='#{type}']")
    end

    refute has_element?(view, "#assignment-form select option[value='scn']")
  end

  test "leave of absence does not inflate resident Total Shifts", %{conn: conn} do
    assert {:ok, result, []} = ScheduleImporter.import_csv(Fixtures.csv(["LOA", "OB", "LOA"]))
    [resident] = Residents.list_residents_for_schedule(result.schedule_id)
    {:ok, view, _} = live(conn, "/residents/#{resident.id}")

    assert has_element?(
             view,
             "#sticky-stats div[title^='Total scheduled service blocks'] p.text-xl",
             "1"
           )
  end
end
