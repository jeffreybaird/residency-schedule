defmodule ResidencyScheduleWeb.DailyAssignmentIntegrationTest do
  use ResidencyScheduleWeb.ConnCase
  doctest ResidencyScheduleWeb.DailyAssignments
  import Phoenix.LiveViewTest
  import ResidencySchedule.QgendaDetailFixtures
  alias ResidencySchedule.{DetailedSchedules, Residents, Rotations, Schedules}
  alias ResidencySchedule.Importer.QgendaPreview

  setup :authenticate_session

  setup do
    data = seed_detail_roster()
    admin = ResidencySchedule.ScheduleFixtures.admin_user()
    {:ok, preview} = detail_preview()
    {:ok, _} = DetailedSchedules.commit(preview, admin)
    Map.put(data, :admin, admin)
  end

  test "rotation modal includes resident name and date-grouped assignments and notes", ctx do
    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.iris.id}")
    open_rotation(view)
    assert has_element?(view, "#shift-coworkers-modal-title", "Iris Reed")
    assert has_element?(view, "#shift-coworkers-modal-title", "Gynecology")

    assert has_element?(
             view,
             "#rotation-daily-assignments [data-date='2026-12-28']",
             "GOG Continuity Clinic AM"
           )

    assert has_element?(
             view,
             "#rotation-daily-assignments [data-date='2026-12-29']",
             "GOG Continuity Clinic PM"
           )

    assert has_element?(view, "#rotation-daily-assignments", "Bring simulation kit")
    refute has_element?(view, "#rotation-daily-assignments", "Sick Backup")
    assert_neutral(view, "#rotation-daily-assignments")
  end

  test "range context excludes another resident and dates outside the selected rotation", ctx do
    {:ok, rows} = outside_preview()
    {:ok, _} = DetailedSchedules.commit(rows, ctx.admin)

    result =
      DetailedSchedules.list_for_resident_range(ctx.iris.id, ~D[2026-12-28], ~D[2027-01-03])

    assert length(result) == 5
    assert Enum.all?(result, &(&1.schedule_resident_id == ctx.iris.id))
    assert Enum.all?(result, &(Date.compare(&1.date, ~D[2027-01-03]) != :gt))
    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.iris.id}")
    open_rotation(view)
    refute has_element?(view, "#rotation-daily-assignments [data-date='2027-01-05']")
    refute has_element?(view, "#rotation-daily-assignments", "Juniper Vale")
  end

  test "range context safely rejects invalid, reversed, and excessive ranges", ctx do
    for {first, last} <- [
          {nil, ~D[2027-01-03]},
          {"bad", "bad"},
          {~D[2027-01-03], ~D[2026-12-28]},
          {~D[2020-01-01], ~D[2030-01-01]}
        ] do
      assert DetailedSchedules.list_for_resident_range(ctx.iris.id, first, last) == []
    end
  end

  test "earlier-year rotation modal uses that appearance's assignments", ctx do
    {:ok, prior} = Schedules.upsert_schedule(2025, "2025–2026")

    {:ok, earlier} =
      Residents.insert_resident(prior.id, %{
        name: "Iris Reed",
        resident_id: ctx.iris.resident_id,
        position_code: "R1-1",
        residency_year: 1,
        schedule_number: 1
      })

    {:ok, _} =
      Rotations.insert_rotations(earlier.id, [
        %{
          slot_index: 0,
          start_date: ~D[2025-12-28],
          end_date: ~D[2026-01-03],
          rotation_type: :strong_gynecology
        }
      ])

    binary =
      mutate_detail_workbook("xl/sharedStrings.xml", fn xml ->
        xml
        |> String.replace("2026", "2025")
        |> String.replace("2027", "2026")
        |> String.replace("GOG Continuity Clinic PM", "Historic Clinic PM")
      end)

    {:ok, previous} = QgendaPreview.prepare(binary, academic_year: 2025)
    {:ok, _} = DetailedSchedules.commit(previous, ctx.admin)
    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.iris.id}")
    view |> element("#rotation-entry-strong_gynecology-0-2025-12-28-2026-01-03") |> render_click()

    assert has_element?(
             view,
             "#rotation-daily-assignments [data-date='2025-12-29']",
             "Historic Clinic PM"
           )

    refute has_element?(view, "#rotation-daily-assignments [data-date='2026-12-29']")
  end

  test "forged schedule IDs and dates cannot open an unrelated detail range", ctx do
    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.iris.id}")

    for params <- [
          %{"rotation-type" => "strong_gynecology", "start-date" => "bad", "end-date" => "bad"},
          %{
            "rotation-type" => "strong_gynecology",
            "start-date" => "2026-12-28",
            "end-date" => "2027-01-03",
            "schedule-id" => "999999"
          },
          %{
            "rotation-type" => "strong_gynecology",
            "start-date" => "2020-01-01",
            "end-date" => "2030-01-01",
            "schedule-id" => to_string(ctx.schedule.id)
          }
        ] do
      render_click(view, "open_shift_coworkers", params)
      refute has_element?(view, "#shift-coworkers-modal")
    end
  end

  test "rotation modal supports Escape and close controls", ctx do
    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.iris.id}")
    open_rotation(view)

    assert has_element?(
             view,
             "#shift-coworkers-modal[role='dialog'][aria-modal='true'][phx-window-keydown='close_shift_coworkers'][phx-key='Escape']"
           )

    view |> element("#shift-coworkers-modal") |> render_keydown(%{"key" => "Escape"})
    refute has_element?(view, "#shift-coworkers-modal")
    open_rotation(view)
    view |> element("#shift-coworkers-modal button[aria-label='Close']") |> render_click()
    refute has_element?(view, "#shift-coworkers-modal")
  end

  test "calendar groups a person's rotation and detailed tasks in the same row", ctx do
    {:ok, view, _} = live(ctx.conn, "/calendar?view=day&date=2026-12-29")
    selector = "#day-activities [data-resident-id='#{ctx.iris.resident_id}']"
    assert has_element?(view, selector, "Iris Reed")
    assert has_element?(view, selector, "Gynecology")
    assert has_element?(view, selector, "GOG Continuity Clinic PM")
    assert has_element?(view, selector, "Bring simulation kit")

    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query(selector)
           |> Enum.count() == 1

    assert_neutral(view, "#day-activities")
  end

  test "calendar task-only residents remain visible and resident filters apply", ctx do
    {:ok, view, _} = live(ctx.conn, "/calendar?view=day&date=2026-12-30")

    assert has_element?(
             view,
             "#day-activities [data-resident-id='#{ctx.juniper.resident_id}']",
             "Sick Backup"
           )

    render_click(view, "toggle_resident_filter", %{"id" => to_string(ctx.iris.resident_id)})
    refute has_element?(view, "#day-activities [data-resident-id='#{ctx.juniper.resident_id}']")
  end

  test "task-only resident dates remain accessible with neutral empty-state wording", ctx do
    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.juniper.id}")
    view |> form("#resident-activity-date-form", %{"date" => "2026-12-30"}) |> render_change()
    assert has_element?(view, "#resident-day-activities", "Sick Backup")
    assert_neutral(view, "#resident-day-activities")
    view |> form("#resident-activity-date-form", %{"date" => "2027-01-04"}) |> render_change()
    assert has_element?(view, "#resident-day-activities", "No daily assignments recorded")
    refute has_element?(view, "#resident-day-activities", "Available")
  end

  test "calendar empty detail is neutral", ctx do
    {:ok, view, _} = live(ctx.conn, "/calendar?view=day&date=2027-01-04")
    assert has_element?(view, "#day-activities", "No daily assignments recorded")
    assert_neutral(view, "#day-activities")
  end

  test "range retrieval batches queries rather than fetching each date", ctx do
    recipient = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:residency_schedule, :repo, :query],
        fn _, _, metadata, _ ->
          if String.starts_with?(metadata.query, "SELECT"), do: send(recipient, :detail_query)
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)

    assert DetailedSchedules.list_for_resident_range(ctx.iris.id, ~D[2026-12-28], ~D[2026-12-28]) !=
             []

    single = query_count()

    assert DetailedSchedules.list_for_resident_range(ctx.iris.id, ~D[2026-12-28], ~D[2027-01-03]) !=
             []

    assert query_count() == single
    assert single <= 4
  end

  test "schedule notes render as text instead of active markup", ctx do
    binary =
      mutate_detail_workbook(
        "xl/sharedStrings.xml",
        &String.replace(&1, "Bring simulation kit", "&lt;script&gt;alert(1)&lt;/script&gt;")
      )

    {:ok, preview} = detail_preview(binary)
    {:ok, _} = DetailedSchedules.commit(preview, ctx.admin)
    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.iris.id}")
    open_rotation(view)
    assert has_element?(view, "#rotation-daily-assignments", "<script>alert(1)</script>")
    refute has_element?(view, "#rotation-daily-assignments script")
  end

  defp query_count do
    receive do
      :detail_query -> 1 + query_count()
    after
      0 -> 0
    end
  end

  defp open_rotation(view),
    do:
      view
      |> element("#rotation-entry-strong_gynecology-0-2026-12-28-2027-01-03")
      |> render_click()

  defp outside_preview do
    mutate_detail_workbook(
      "xl/sharedStrings.xml",
      &String.replace(&1, "December 29, 2026", "January 5, 2027")
    )
    |> detail_preview()
  end

  defp assert_neutral(view, selector) do
    for text <- [
          "QGenda",
          "Source details",
          "Page 1",
          "import ",
          "Missing detail does not",
          "Period unspecified",
          "Location unspecified"
        ] do
      refute has_element?(view, selector, text)
    end
  end
end
