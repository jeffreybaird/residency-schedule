defmodule ResidencyScheduleWeb.ResidentLiveTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest

  alias ResidencySchedule.Rotations

  setup :authenticate_session

  describe "unauthenticated access" do
    test "redirects to /login when no session", %{conn: _conn} do
      result = get(Phoenix.ConnTest.build_conn(), "/residents/1")
      assert redirected_to(result) == "/login"
    end
  end

  describe "resident page" do
    setup %{conn: conn} do
      %{schedule_id: _sid} = seed_schedule()
      resident = ResidencySchedule.Residents.get_resident_by_position!("R4-1")
      {:ok, view, html} = live(conn, "/residents/#{resident.id}")
      %{view: view, html: html, resident: resident}
    end

    test "renders resident name", %{html: html, resident: resident} do
      assert html =~ resident.name
    end

    test "renders position code", %{html: html, resident: resident} do
      assert html =~ resident.position_code
    end

    test "does not render the removed rotation table title row above the grid", %{html: html} do
      refute html =~ "Rotation Table"
    end

    test "shows Set as Home button when no home resident set", %{html: html} do
      assert html =~ "Set as Home"
    end

    test "shows Home badge when resident is home resident", %{conn: conn} do
      resident = ResidencySchedule.Residents.get_resident_by_position!("R4-1")

      conn =
        conn
        |> Plug.Test.init_test_session(authenticated: true, resident_id: resident.id)

      {:ok, _view, html} = live(conn, "/residents/#{resident.id}")
      assert html =~ "✓ Home"
    end

    test "filters the rotation table to a selected service", %{view: view, resident: resident} do
      [selected_type | other_types] = resident_service_types(resident)
      other_type = hd(other_types)

      view
      |> element("#service-filter-toggle")
      |> render_click()

      view
      |> element("#service-filter-option-#{selected_type}")
      |> render_click()

      assert has_element?(view, "#rotation-table tbody tr[data-rotation-type='#{selected_type}']")
      refute has_element?(view, "#rotation-table tbody tr[data-rotation-type='#{other_type}']")
    end

    test "supports selecting multiple services at once", %{view: view, resident: resident} do
      [first_type, second_type | _rest] = resident_service_types(resident)

      view
      |> element("#service-filter-toggle")
      |> render_click()

      view
      |> element("#service-filter-option-#{first_type}")
      |> render_click()

      view
      |> element("#service-filter-option-#{second_type}")
      |> render_click()

      assert has_element?(view, "#rotation-table tbody tr[data-rotation-type='#{first_type}']")
      assert has_element?(view, "#rotation-table tbody tr[data-rotation-type='#{second_type}']")
    end

    test "keeps the filter panel open after selecting a service", %{
      view: view,
      resident: resident
    } do
      [selected_type | _rest] = resident_service_types(resident)

      view
      |> element("#service-filter-toggle")
      |> render_click()

      assert has_element?(view, "#service-filter-panel")

      view
      |> element("#service-filter-option-#{selected_type}")
      |> render_click()

      assert has_element?(view, "#service-filter-panel")
    end

    test "opens shift coworkers modal when clicking a rotation row", %{
      view: view,
      resident: resident
    } do
      row_id =
        resident.id
        |> Rotations.effective_segments_for_resident()
        |> Enum.find(fn s -> s.rotation_type == "oncology" end)
        |> case do
          nil -> flunk("expected an oncology segment in fixture")
          seg -> "rotation-entry-oncology-#{seg.slot_index}-#{Date.to_iso8601(seg.start_date)}"
        end

      assert has_element?(view, "##{row_id}")

      view
      |> element("##{row_id}")
      |> render_click()

      assert has_element?(view, "#shift-coworkers-modal")
      assert has_element?(view, "#shift-coworkers-list")
    end

    test "does not open coworkers modal when clicking an OFF row", %{view: view} do
      html = render(view)

      case Regex.run(~r/id="(rotation-entry-off-[^"]+)"/, html) do
        [_, row_id] ->
          view
          |> element("##{row_id}")
          |> render_click()

          refute has_element?(view, "#shift-coworkers-modal")

        nil ->
          :ok
      end
    end

    test "closes the filter panel when the menu button is clicked again", %{
      view: view,
      resident: resident
    } do
      [selected_type | _rest] = resident_service_types(resident)

      view
      |> element("#service-filter-toggle")
      |> render_click()

      assert has_element?(view, "#service-filter-panel")

      view
      |> element("#service-filter-option-#{selected_type}")
      |> render_click()

      assert has_element?(view, "#service-filter-panel")

      view
      |> element("#service-filter-toggle")
      |> render_click()

      refute has_element?(view, "#service-filter-panel")
    end
  end

  defp resident_service_types(resident) do
    resident.id
    |> Rotations.effective_segments_for_resident()
    |> Enum.map(& &1.rotation_type)
    |> Enum.uniq()
    |> Enum.reject(&(&1 == "off"))
  end
end
