defmodule ResidencyScheduleWeb.GanttRotationGapTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest
  import ResidencySchedule.QgendaDetailFixtures
  alias ResidencySchedule.{DetailedSchedules, Rotations}

  setup :authenticate_session

  test "same-service blocks separated by a missing week retain separate pills and exclude gap tasks",
       %{conn: conn} do
    data = seed_detail_roster()

    {:ok, _} =
      Rotations.insert_rotations(data.iris.id, [
        %{
          slot_index: 1,
          start_date: ~D[2027-01-11],
          end_date: ~D[2027-01-17],
          rotation_type: :strong_gynecology
        }
      ])

    rotations = Rotations.list_rotations_for_resident(data.iris.id)
    first = Enum.find(rotations, &(&1.start_date == ~D[2026-12-28]))
    later = Enum.find(rotations, &(&1.start_date == ~D[2027-01-11]))

    binary =
      mutate_detail_workbook("xl/sharedStrings.xml", fn xml ->
        xml
        |> String.replace("December 29, 2026", "January 5, 2027")
        |> String.replace("GOG Continuity Clinic PM", "Gap Clinic PM")
      end)

    {:ok, preview} = detail_preview(binary)
    {:ok, _} = DetailedSchedules.commit(preview, ResidencySchedule.ScheduleFixtures.admin_user())

    assert Enum.any?(
             DetailedSchedules.list_for_resident(data.iris.id, ~D[2027-01-05]),
             &(&1.raw_task == "Gap Clinic PM")
           )

    {:ok, view, _} = live(conn, "/schedule")
    assert has_element?(view, "button[data-rotation-id='#{first.id}']")
    assert has_element?(view, "button[data-rotation-id='#{later.id}']")
    view |> element("button[data-rotation-id='#{first.id}']") |> render_click()

    assert has_element?(
             view,
             "#gantt-rotation-dates[data-start-date='2026-12-28'][data-end-date='2027-01-03']"
           )

    refute has_element?(view, "#gantt-daily-assignments", "Gap Clinic PM")
    render_click(view, "close_rotation_details", %{})
    view |> element("button[data-rotation-id='#{later.id}']") |> render_click()

    assert has_element?(
             view,
             "#gantt-rotation-dates[data-start-date='2027-01-11'][data-end-date='2027-01-17']"
           )

    refute has_element?(view, "#gantt-daily-assignments", "Gap Clinic PM")
  end
end
