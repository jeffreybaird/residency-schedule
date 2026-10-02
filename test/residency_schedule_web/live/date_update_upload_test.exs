defmodule ResidencyScheduleWeb.DateUpdateUploadTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest

  alias ResidencySchedule.Importer.ScheduleImporter
  alias ResidencySchedule.{Residents, Schedules}

  @base ",Dates,2026-12-01\n,,2027-01-31\n,,Events\nR1-1,Original,FLOAT\nR1-2,Other,OB\n"
  @patch ",Dates,2027-01-04\n,,2027-01-05\n,,Events\nR1-1,Original,AMB\n"

  setup %{conn: conn} do
    {:ok, result, _} = ScheduleImporter.import_csv(@base)
    %{conn: conn} = admin_authenticate_session(%{conn: conn})
    {:ok, view, _} = live(conn, "/admin/upload")
    %{view: view, conn: conn, schedule_id: result.schedule_id}
  end

  test "date mode reviews selected year and range, keeps identity locked, and confirms partial update",
       context do
    view = context.view

    first =
      context.schedule_id
      |> Residents.list_residents_for_schedule()
      |> Enum.find(&(&1.position_code == "R1-1"))

    assert has_element?(view, "#import-mode option[value='update_dates']", "Update dates")

    view
    |> form("form[phx-submit='save']", %{"mode" => "update_dates", "academic_year" => "2026"})
    |> render_change()

    assert has_element?(view, "#target-academic-year option[value='2026']")
    upload(view)
    assert has_element?(view, "#date-update-review", "2026–2027")
    assert has_element?(view, "#date-update-review", "2027-01-04")
    assert has_element?(view, "#date-update-review", "2027-01-05")
    assert has_element?(view, "#date-update-review", "preserved")
    refute has_element?(view, "select[name='link[R1-1]']")
    assert hd(Residents.get_resident!(first.id).rotations).rotation_type == "float"
    view |> form("form[phx-submit='confirm']") |> render_submit()
    assert_redirect(view, "/?schedule_id=#{context.schedule_id}")
    assert Residents.get_resident!(first.id).resident_id == first.resident_id
    assert length(Residents.get_resident!(first.id).rotations) == 3
    assert Schedules.get_by_year(2027) == nil
    assert length(Residents.list_residents_for_schedule(context.schedule_id)) == 2
  end

  test "split FLOAT intervals and inserted assignment all render in schedule grid", context do
    assert {:ok, _, _} =
             ScheduleImporter.import_csv(@patch, mode: :update_dates, academic_year: 2026)

    {:ok, view, _} = live(context.conn, "/schedule?schedule_id=#{context.schedule_id}")

    first =
      context.schedule_id
      |> Residents.list_residents_for_schedule()
      |> Enum.find(&(&1.position_code == "R1-1"))

    assert has_element?(view, "a[href='/residents/#{first.id}']")
    # All three cells must survive repeated local source slot indices and keep their order.
    labels =
      view
      |> element("tbody tr", first.name)
      |> render()
      |> then(&("<table>" <> &1 <> "</table>"))
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("td span")
      |> Enum.map(&LazyHTML.text/1)

    assert labels == ["FLOAT", "AMB", "FLOAT"]

    second =
      context.schedule_id
      |> Residents.list_residents_for_schedule()
      |> Enum.find(&(&1.position_code == "R1-2"))

    assert has_element?(view, "a[href='/residents/#{second.id}']")

    row =
      view
      |> element("tbody tr", second.name)
      |> render()
      |> then(&("<table>" <> &1 <> "</table>"))
      |> LazyHTML.from_fragment()

    assert row |> LazyHTML.query("td span") |> Enum.map(&LazyHTML.text/1) == ["OB"]
    assert row |> LazyHTML.query("td[colspan='3']") |> Enum.count() == 1
  end

  test "resident detail displays both FLOAT fragments and exact inserted dates", context do
    assert {:ok, _, _} =
             ScheduleImporter.import_csv(@patch, mode: :update_dates, academic_year: 2026)

    first =
      context.schedule_id
      |> Residents.list_residents_for_schedule()
      |> Enum.find(&(&1.position_code == "R1-1"))

    {:ok, view, _} = live(context.conn, "/residents/#{first.id}")

    for {type, start_date, end_date} <- [
          {"float", "2026-12-01", "2027-01-03"},
          {"ambulatory", "2027-01-04", "2027-01-05"},
          {"float", "2027-01-06", "2027-01-31"}
        ] do
      assert has_element?(
               view,
               "[data-rotation-type='#{type}'][phx-value-start-date='#{start_date}'][phx-value-end-date='#{end_date}']"
             )
    end
  end

  defp upload(view) do
    file =
      file_input(view, "form[phx-submit='save']", :schedule_csv, [
        %{name: "patch.csv", content: @patch, type: "text/csv"}
      ])

    render_upload(file, "patch.csv")
    view |> form("form[phx-submit='save']") |> render_submit()
  end

  test "OFF coworkers use actual dates after split slots and exclude a working resident",
       context do
    patch = String.replace(@patch, ",AMB", ",OFF")

    assert {:ok, _, _} =
             ScheduleImporter.import_csv(patch, mode: :update_dates, academic_year: 2026)

    residents = Residents.list_residents_for_schedule(context.schedule_id)
    first = Enum.find(residents, &(&1.position_code == "R1-1"))
    second = Enum.find(residents, &(&1.position_code == "R1-2"))
    {:ok, view, _} = live(context.conn, "/residents/#{first.id}")

    view
    |> element(
      "[data-rotation-type='off'][phx-value-start-date='2027-01-04'][phx-value-end-date='2027-01-05']"
    )
    |> render_click()

    assert has_element?(view, "#shift-coworkers-modal")
    assert has_element?(view, "#shift-coworkers-list a[href='/residents/#{first.id}']")
    refute has_element?(view, "#shift-coworkers-list a[href='/residents/#{second.id}']")
  end

  test "schedule grid keeps concurrent rotation types visible on their overlapping dates",
       context do
    first =
      context.schedule_id
      |> Residents.list_residents_for_schedule()
      |> Enum.find(&(&1.position_code == "R1-1"))

    assert {:ok, 1} =
             ResidencySchedule.Rotations.insert_rotations(first.id, [
               %{
                 slot_index: 9,
                 start_date: ~D[2026-12-10],
                 end_date: ~D[2026-12-13],
                 rotation_type: :highland_night_float
               }
             ])

    assert {:ok, _, _} =
             ScheduleImporter.import_csv(@patch, mode: :update_dates, academic_year: 2026)

    {:ok, view, _} = live(context.conn, "/schedule?schedule_id=#{context.schedule_id}")

    cells =
      view
      |> element("tbody tr", first.name)
      |> render()
      |> then(&("<table>" <> &1 <> "</table>"))
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("td")

    assert Enum.any?(cells, fn cell ->
             labels = cell |> LazyHTML.query("span") |> Enum.map(&LazyHTML.text/1)
             "FLOAT" in labels and "HNF" in labels
           end)
  end

  test "editor displays overlapping assignments at their actual dates without database writes",
       context do
    first =
      context.schedule_id
      |> Residents.list_residents_for_schedule()
      |> Enum.find(&(&1.position_code == "R1-1"))

    assert {:ok, 1} =
             ResidencySchedule.Rotations.insert_rotations(first.id, [
               %{
                 slot_index: 9,
                 start_date: ~D[2026-12-10],
                 end_date: ~D[2026-12-13],
                 rotation_type: :highland_night_float
               }
             ])

    assert {:ok, _, _} =
             ScheduleImporter.import_csv(@patch, mode: :update_dates, academic_year: 2026)

    before = Residents.get_resident!(first.id)
    {:ok, view, _} = live(context.conn, "/admin/edit")

    view
    |> form("form[phx-submit='load_schedule']", %{"schedule_id" => to_string(context.schedule_id)})
    |> render_submit()

    refute has_element?(view, "#edit-load-error")
    assert has_element?(view, "#editor-grid")
    assert has_element?(view, "[data-start-date='2026-12-10'][data-end-date='2026-12-13']", "HNF")
    assert has_element?(view, "form[phx-submit='load_schedule']")
    refute has_element?(view, "[phx-click='open_picker']")
    assert Residents.get_resident!(first.id) == before
  end
end
