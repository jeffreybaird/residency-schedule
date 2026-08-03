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

    test "nav labels the home link My page for a resident", %{
      conn: conn,
      user: user,
      resident: resident
    } do
      {:ok, _} = ResidencySchedule.Accounts.set_home_resident(user, resident.id)
      conn = get(conn, "/residents/#{resident.id}")
      assert html_response(conn, 200) =~ "My page"
    end

    test "shows Home badge when resident is home resident", %{conn: conn, user: user} do
      resident = ResidencySchedule.Residents.get_resident_by_position!("R4-1")

      ResidencySchedule.Accounts.set_home_resident(user, resident.id)

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
      |> element(~s(#service-filter-panel button[phx-value-service="#{selected_type}"]))
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
      |> element(~s(#service-filter-panel button[phx-value-service="#{first_type}"]))
      |> render_click()

      view
      |> element(~s(#service-filter-panel button[phx-value-service="#{second_type}"]))
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
      |> element(~s(#service-filter-panel button[phx-value-service="#{selected_type}"]))
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
          nil ->
            flunk("expected an oncology segment in fixture")

          seg ->
            "rotation-entry-oncology-#{seg.slot_index}-#{Date.to_iso8601(seg.start_date)}-#{Date.to_iso8601(seg.end_date)}"
        end

      assert has_element?(view, "##{row_id}")

      view
      |> element("##{row_id}")
      |> render_click()

      assert has_element?(view, "#shift-coworkers-modal")
      assert has_element?(view, "#shift-coworkers-list")
    end

    test "opens off coworkers modal when clicking an OFF row", %{view: view} do
      html = render(view)

      case Regex.run(~r/id="(rotation-entry-off-[^"]+)"/, html) do
        [_, row_id] ->
          view
          |> element("##{row_id}")
          |> render_click()

          assert has_element?(view, "#shift-coworkers-modal")
          assert has_element?(view, "#shift-coworkers-modal-title")

        nil ->
          :ok
      end
    end

    test "shows OFF as an option in the rotation filter dropdown", %{view: view} do
      view
      |> element("#service-filter-toggle")
      |> render_click()

      assert has_element?(
               view,
               ~s(#service-filter-panel button[phx-value-service="off"])
             )
    end

    test "filters the rotation table to OFF entries when OFF is selected", %{view: view} do
      view
      |> element("#service-filter-toggle")
      |> render_click()

      view
      |> element(~s(#service-filter-panel button[phx-value-service="off"]))
      |> render_click()

      assert has_element?(view, "#rotation-table tbody tr[data-rotation-type='off']")
      refute has_element?(view, "#rotation-table tbody tr[data-rotation-type='oncology']")
    end

    test "filter toggle button is shown even when a filter has been applied", %{
      view: view,
      resident: resident
    } do
      [selected_type | _rest] = resident_service_types(resident)

      view
      |> element("#service-filter-toggle")
      |> render_click()

      view
      |> element(~s(#service-filter-panel button[phx-value-service="#{selected_type}"]))
      |> render_click()

      assert has_element?(view, "#service-filter-toggle")
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
      |> element(~s(#service-filter-panel button[phx-value-service="#{selected_type}"]))
      |> render_click()

      assert has_element?(view, "#service-filter-panel")

      view
      |> element("#service-filter-toggle")
      |> render_click()

      refute has_element?(view, "#service-filter-panel")
    end
  end

  describe "resident page for a user-role follower" do
    setup do
      {:ok, follower} =
        ResidencySchedule.Accounts.create_user(%{
          email: "partner-#{System.unique_integer()}@gmail.com"
        })

      {:ok, follower} = ResidencySchedule.Accounts.approve_user(follower)
      conn = Plug.Test.init_test_session(build_conn(), user_id: follower.id)

      %{schedule_id: _sid} = seed_schedule()
      resident = ResidencySchedule.Residents.get_resident_by_position!("R4-1")
      %{conn: conn, resident: resident, follower: follower}
    end

    test "shows a Follow button instead of Set as Home", %{conn: conn, resident: resident} do
      {:ok, _view, html} = live(conn, "/residents/#{resident.id}")
      assert html =~ "Follow"
      refute html =~ "Set as Home"
    end

    test "renders the tour anchor and user role for the guided tour", %{
      conn: conn,
      resident: resident
    } do
      {:ok, _view, html} = live(conn, "/residents/#{resident.id}")
      assert html =~ ~s(id="tour-follow-home")
      assert html =~ ~s(data-tour-role="user")
    end

    test "shows a Following badge once followed", %{
      conn: conn,
      resident: resident,
      follower: follower
    } do
      {:ok, _} = ResidencySchedule.Accounts.set_home_resident(follower, resident.id)
      {:ok, _view, html} = live(conn, "/residents/#{resident.id}")
      assert html =~ "✓ Following"
    end

    test "nav labels the followed resident link Following", %{
      conn: conn,
      resident: resident,
      follower: follower
    } do
      {:ok, _} = ResidencySchedule.Accounts.set_home_resident(follower, resident.id)
      conn = get(conn, "/residents/#{resident.id}")
      assert html_response(conn, 200) =~ "Following"
      refute html_response(conn, 200) =~ "My page"
    end
  end

  describe "multi-year career" do
    test "renders rotations from every academic year on one continuous page", %{conn: conn} do
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
        Rotations.insert_rotations(sr_2023.id, [
          %{
            slot_index: 0,
            start_date: ~D[2023-07-03],
            end_date: ~D[2023-07-09],
            rotation_type: :oncology
          }
        ])

      {:ok, _} =
        Rotations.insert_rotations(sr_2026.id, [
          %{
            slot_index: 0,
            start_date: ~D[2026-07-06],
            end_date: ~D[2026-07-12],
            rotation_type: :rei
          }
        ])

      # Open the 2023 record; the page should still show the 2026 rotation,
      # under a year divider, so the user can scroll into the next year.
      {:ok, _view, html} = live(conn, "/residents/#{sr_2023.id}")

      assert html =~ "2023–2024"
      assert html =~ "2026–2027"
      assert html =~ "rotation-entry-oncology-0-2023-07-03-2023-07-09"
      assert html =~ "rotation-entry-rei-0-2026-07-06-2026-07-12"
    end
  end

  describe "row anchor helpers" do
    alias ResidencyScheduleWeb.ResidentLive.Show

    test "entry_row_id builds a date-unique id" do
      entry = %{
        rotation_type: "oncology",
        slot_index: 2,
        start_date: ~D[2024-07-01],
        end_date: ~D[2024-07-15]
      }

      assert Show.entry_row_id(entry) == "rotation-entry-oncology-2-2024-07-01-2024-07-15"
    end

    test "today_anchor_id picks the current or next upcoming entry" do
      entries = [
        %{
          rotation_type: "oncology",
          slot_index: 0,
          start_date: ~D[2024-07-01],
          end_date: ~D[2024-07-15]
        },
        %{
          rotation_type: "elective",
          slot_index: 1,
          start_date: ~D[2024-08-01],
          end_date: ~D[2024-08-15]
        }
      ]

      assert Show.today_anchor_id(entries, ~D[2024-07-20]) ==
               "rotation-entry-elective-1-2024-08-01-2024-08-15"
    end

    test "today_anchor_id falls back to the first entry when today is past everything" do
      entries = [
        %{
          rotation_type: "oncology",
          slot_index: 0,
          start_date: ~D[2024-07-01],
          end_date: ~D[2024-07-15]
        }
      ]

      assert Show.today_anchor_id(entries, ~D[2025-01-01]) ==
               "rotation-entry-oncology-0-2024-07-01-2024-07-15"
    end

    test "today_anchor_id returns nil when there are no entries" do
      assert Show.today_anchor_id([], ~D[2024-07-20]) == nil
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
