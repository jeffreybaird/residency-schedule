defmodule ResidencyScheduleWeb.GanttRotationDetailsTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest
  import ResidencySchedule.QgendaDetailFixtures
  alias ResidencySchedule.{DetailedSchedules, Residents, Rotations, Schedules}
  alias ResidencySchedule.Importer.QgendaPreview

  doctest ResidencyScheduleWeb.ScheduleLive.Index

  setup :authenticate_session

  setup do
    data = seed_detail_roster()
    admin = ResidencySchedule.ScheduleFixtures.admin_user()
    {:ok, preview} = detail_preview()
    {:ok, _} = DetailedSchedules.commit(preview, admin)
    [rotation] = Rotations.list_rotations_for_resident(data.iris.id)
    Map.merge(data, %{admin: admin, rotation: rotation})
  end

  test "native rotation button opens resident-scoped dates, assignments and notes", ctx do
    {:ok, view, _} = live(ctx.conn, "/schedule")
    assert has_element?(view, pill(ctx.rotation), "GYN")
    view |> element(pill(ctx.rotation)) |> render_click()

    assert has_element?(
             view,
             "#gantt-rotation-modal[role='dialog'][aria-modal='true'][aria-labelledby='gantt-rotation-modal-title']"
           )

    assert has_element?(view, "#gantt-rotation-modal-title", "Iris Reed")
    assert has_element?(view, "#gantt-rotation-modal-title", "Gynecology")

    assert has_element?(
             view,
             "#gantt-rotation-dates[data-start-date='2026-12-28'][data-end-date='2027-01-03']"
           )

    assert has_element?(
             view,
             "#gantt-daily-assignments [data-date='2026-12-29']",
             "GOG Continuity Clinic PM"
           )

    assert has_element?(view, "#gantt-daily-assignments", "Bring simulation kit")
    refute has_element?(view, "#gantt-daily-assignments", "Sick Backup")
    assert_neutral(view)
  end

  test "clicking another person's pill uses their authoritative imported name", ctx do
    rotation = add_rotation(ctx.juniper.id, :strong_gynecology, ~D[2026-12-28], ~D[2027-01-03], 0)
    {:ok, view, _} = live(ctx.conn, "/schedule")
    view |> element(pill(rotation)) |> render_click()
    assert has_element?(view, "#gantt-rotation-modal-title", "Juniper Vale")
    assert has_element?(view, "#gantt-daily-assignments", "Sick Backup")
    refute has_element?(view, "#gantt-daily-assignments", "Bring simulation kit")
  end

  test "forged identifiers cannot create a modal and client dates cannot expand a real pill",
       ctx do
    {:ok, view, _} = live(ctx.conn, "/schedule")

    for id <- ["bad", "-1", "999999"] do
      render_click(view, "open_rotation_details", %{"rotation-id" => id, "cell-id" => id})
      refute has_element?(view, "#gantt-rotation-modal")
    end

    view
    |> element(pill(ctx.rotation))
    |> render_click(%{
      "start-date" => "2020-01-01",
      "end-date" => "2030-01-01",
      "resident-id" => to_string(ctx.juniper.resident_id)
    })

    assert has_element?(view, "#gantt-rotation-modal-title", "Iris Reed")

    assert has_element?(
             view,
             "#gantt-rotation-dates[data-start-date='2026-12-28'][data-end-date='2027-01-03']"
           )
  end

  test "Escape, close button and backdrop close the modal", ctx do
    {:ok, view, _} = live(ctx.conn, "/schedule")
    view |> element(pill(ctx.rotation)) |> render_click()

    assert has_element?(
             view,
             "#gantt-rotation-modal[phx-window-keydown='close_rotation_details'][phx-key='Escape']"
           )

    view |> element("#gantt-rotation-modal") |> render_keydown(%{"key" => "Escape"})
    refute has_element?(view, "#gantt-rotation-modal")
    view |> element(pill(ctx.rotation)) |> render_click()
    view |> element("#gantt-rotation-modal button[aria-label='Close']") |> render_click()
    refute has_element?(view, "#gantt-rotation-modal")
    view |> element(pill(ctx.rotation)) |> render_click()
    view |> element("#gantt-rotation-modal [data-role='backdrop']") |> render_click()
    refute has_element?(view, "#gantt-rotation-modal")
  end

  test "filters and year navigation clear the modal and stale filtered-out buttons cannot reopen it",
       ctx do
    {:ok, view, _} = live(ctx.conn, "/schedule")

    token =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(pill(ctx.rotation))
      |> LazyHTML.attribute("phx-value-cell-id")
      |> hd()

    view |> element(pill(ctx.rotation)) |> render_click()
    render_click(view, "filter_year", %{"year" => "1"})
    refute has_element?(view, "#gantt-rotation-modal")

    render_click(view, "open_rotation_details", %{
      "rotation-id" => to_string(ctx.rotation.id),
      "cell-id" => token
    })

    refute has_element?(view, "#gantt-rotation-modal")
    render_click(view, "filter_year", %{"year" => "all"})
    view |> element(pill(ctx.rotation)) |> render_click()
    render_click(view, "view_academic_year", %{"aca_year" => "2025"})
    refute has_element?(view, "#gantt-rotation-modal")
    view |> element(pill(ctx.rotation)) |> render_click()
    render_click(view, "scroll_to_schedule", %{"id" => to_string(ctx.schedule.id)})
    refute has_element?(view, "#gantt-rotation-modal")
  end

  test "earlier-year pills retain their own resident appearance and scope", ctx do
    {:ok, prior} = Schedules.upsert_schedule(2025, "2025–2026")

    {:ok, earlier} =
      Residents.insert_resident(prior.id, %{
        name: "Iris Reed",
        resident_id: ctx.iris.resident_id,
        position_code: "R1-1",
        residency_year: 1,
        schedule_number: 1
      })

    rotation = add_rotation(earlier.id, :strong_gynecology, ~D[2025-12-28], ~D[2026-01-03], 0)

    binary =
      mutate_detail_workbook("xl/sharedStrings.xml", fn xml ->
        xml
        |> String.replace("2026", "2025")
        |> String.replace("2027", "2026")
        |> String.replace("GOG Continuity Clinic PM", "Historic Clinic PM")
      end)

    {:ok, preview} = QgendaPreview.prepare(binary, academic_year: 2025)
    {:ok, _} = DetailedSchedules.commit(preview, ctx.admin)
    {:ok, view, _} = live(ctx.conn, "/schedule")
    assert has_element?(view, pill(rotation))
    assert has_element?(view, pill(ctx.rotation))
    view |> element(pill(rotation)) |> render_click()

    assert has_element?(
             view,
             "#gantt-rotation-dates[data-start-date='2025-12-28'][data-end-date='2026-01-03']"
           )

    assert has_element?(view, "#gantt-daily-assignments", "Historic Clinic PM")
    refute has_element?(view, "#gantt-daily-assignments [data-date='2026-12-29']")
  end

  test "a merged same-service pill covers all adjacent stored rotation blocks", ctx do
    add_rotation(ctx.iris.id, :strong_gynecology, ~D[2027-01-04], ~D[2027-01-10], 1)

    binary =
      mutate_detail_workbook("xl/sharedStrings.xml", fn xml ->
        xml
        |> String.replace("December 29, 2026", "January 5, 2027")
        |> String.replace("GOG Continuity Clinic PM", "Later Clinic PM")
      end)

    {:ok, preview} = detail_preview(binary)
    {:ok, _} = DetailedSchedules.commit(preview, ctx.admin)
    {:ok, view, _} = live(ctx.conn, "/schedule")
    view |> element(pill(ctx.rotation)) |> render_click()

    assert has_element?(
             view,
             "#gantt-rotation-dates[data-start-date='2026-12-28'][data-end-date='2027-01-10']"
           )

    assert has_element?(
             view,
             "#gantt-daily-assignments [data-date='2027-01-05']",
             "Later Clinic PM"
           )
  end

  test "concurrent service pills resolve independently without losing their ranges", ctx do
    oncology = add_rotation(ctx.iris.id, :oncology, ~D[2026-12-28], ~D[2027-01-03], 0)
    {:ok, view, _} = live(ctx.conn, "/schedule")
    assert has_element?(view, pill(ctx.rotation), "GYN")
    assert has_element?(view, pill(oncology), "ONC")
    view |> element(pill(oncology)) |> render_click()
    assert has_element?(view, "#gantt-rotation-modal-title", "Oncology")

    assert has_element?(
             view,
             "#gantt-rotation-dates[data-start-date='2026-12-28'][data-end-date='2027-01-03']"
           )

    assert has_element?(view, "#gantt-daily-assignments", "Bring simulation kit")
  end

  test "a rotation with no daily details has an honest neutral empty state", ctx do
    rotation = add_rotation(ctx.stone.id, :elective, ~D[2027-02-01], ~D[2027-02-07], 2)
    {:ok, view, _} = live(ctx.conn, "/schedule")
    view |> element(pill(rotation)) |> render_click()
    assert has_element?(view, "#gantt-daily-assignments", "No daily assignments recorded")
    refute has_element?(view, "#gantt-daily-assignments", "Available")
    assert_neutral(view)
  end

  defp pill(rotation), do: "button[type='button'][data-rotation-id='#{rotation.id}']"

  defp add_rotation(resident_id, type, first, last, slot) do
    {:ok, _} =
      Rotations.insert_rotations(resident_id, [
        %{
          slot_index: slot,
          start_date: first,
          end_date: last,
          rotation_type: type
        }
      ])

    Rotations.list_rotations_for_resident(resident_id)
    |> Enum.find(
      &(&1.rotation_type == Atom.to_string(type) and &1.start_date == first and
          &1.end_date == last)
    )
  end

  defp assert_neutral(view) do
    for text <- [
          "QGenda",
          "Source details",
          "Page 1",
          "import ",
          "Period unspecified",
          "Location unspecified"
        ] do
      refute has_element?(view, "#gantt-rotation-modal", text)
    end
  end
end
