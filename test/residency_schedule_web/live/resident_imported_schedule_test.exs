defmodule ResidencyScheduleWeb.ResidentImportedScheduleTest do
  use ResidencyScheduleWeb.ConnCase

  import Phoenix.LiveViewTest
  import ResidencySchedule.QgendaDetailFixtures

  alias ResidencySchedule.{DetailedSchedules, Residents, Rotations, Schedules}

  doctest ResidencyScheduleWeb.ResidentLive.Show

  setup :authenticate_session

  setup do
    data = seed_detail_roster()

    {:ok, _} =
      Rotations.insert_rotations(data.iris.id, [
        %{
          slot_index: 1,
          start_date: ~D[2026-10-05],
          end_date: ~D[2026-10-11],
          rotation_type: :strong_gynecology
        }
      ])

    {:ok, preview} = detail_preview(october_workbook())
    {:ok, _} = DetailedSchedules.commit(preview, ResidencySchedule.ScheduleFixtures.admin_user())
    data
  end

  test "imported Saturday night call appears in the main schedule without any base rotation",
       ctx do
    assert Rotations.list_rotations_for_resident(ctx.juniper.id) == []
    [activity] = DetailedSchedules.list_for_resident(ctx.juniper.id, ~D[2026-10-10])
    assert activity.raw_task == "HH Nights 3rd Call"

    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.juniper.id}")

    assert has_element?(view, "#rotation-table tbody tr", "HH Nights 3rd Call")
    assert has_element?(view, "#rotation-table tbody tr", ~r/HH Nights 3rd Call.*Oct 10, 2026/s)
    refute has_element?(view, "#rotation-table tbody tr", "Mystery Service")
    refute has_element?(view, "#rotation-table tbody tr", "Vacation")
  end

  test "activity days split an otherwise OFF week without deleting the remaining OFF dates",
       ctx do
    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.juniper.id}")

    assert has_element?(view, off_row("2026-10-05", "2026-10-06"))
    assert has_element?(view, off_row("2026-10-08", "2026-10-09"))
    assert has_element?(view, off_row("2026-10-11", "2026-10-11"))
    refute has_element?(view, off_row("2026-10-05", "2026-10-11"))

    # Inspect every OFF interval, so a duplicate unsplit interval cannot pass.
    off_rows =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#rotation-table tr[data-rotation-type='off']")

    intervals =
      Enum.zip(
        LazyHTML.attribute(off_rows, "phx-value-start-date"),
        LazyHTML.attribute(off_rows, "phx-value-end-date")
      )

    for {start_date, end_date} <- intervals,
        activity_date <- [~D[2026-10-07], ~D[2026-10-10]] do
      refute activity_date in Date.range(
               Date.from_iso8601!(start_date),
               Date.from_iso8601!(end_date)
             )
    end
  end

  test "multiple literal tasks on one date remain alongside the base rotation", ctx do
    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.iris.id}")

    for task <- ["SMH GYN R2 Day", "HH Nights 3rd Call", "Vacation"] do
      assert has_element?(
               view,
               "#rotation-table tbody tr",
               Regex.compile!("#{task}.*Oct 5, 2026", "s")
             )
    end

    assert has_element?(
             view,
             "#rotation-entry-strong_gynecology-1-2026-10-05-2026-10-11"
           )

    refute has_element?(view, "#rotation-table tbody tr", "Sick Backup")
    refute has_element?(view, "#rotation-table tbody tr", "Mystery Service")
  end

  test "opening an older appearance includes the person's later imported schedule", ctx do
    {:ok, older_schedule} = Schedules.upsert_schedule(2025, "2025–2026")

    {:ok, older} =
      Residents.insert_resident(older_schedule.id, %{
        name: "Juniper Vail",
        resident_id: ctx.juniper.resident_id,
        position_code: "R1-2",
        residency_year: 1,
        schedule_number: 2
      })

    {:ok, _} =
      Rotations.insert_rotations(older.id, [
        %{
          slot_index: 0,
          start_date: ~D[2025-10-06],
          end_date: ~D[2025-10-12],
          rotation_type: :oncology
        }
      ])

    {:ok, view, _} = live(ctx.conn, "/residents/#{older.id}")

    assert has_element?(view, "#rotation-table", "2025–2026")
    assert has_element?(view, "#rotation-table", "2026–2027")
    assert has_element?(view, "#rotation-entry-oncology-0-2025-10-06-2025-10-12")
    assert has_element?(view, "#rotation-table tbody tr", ~r/HH Nights 3rd Call.*Oct 10, 2026/s)
    refute has_element?(view, "#rotation-table tbody tr", "Mystery Service")
  end

  test "daily assignments have their own filter and do not open rotation coworkers", ctx do
    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.iris.id}")
    view |> element("#service-filter-toggle") |> render_click()

    view
    |> element("#service-filter-panel button[phx-value-service='daily_assignments']")
    |> render_click()

    assert has_element?(view, "#rotation-table tbody tr", "HH Nights 3rd Call")

    assert has_element?(
             view,
             "#rotation-table tr[data-entry-kind='activity']",
             "HH Nights 3rd Call"
           )

    refute has_element?(view, "#rotation-table tr[data-rotation-type='strong_gynecology']")
    refute has_element?(view, "#rotation-table tr[data-rotation-type='off']")
    refute has_element?(view, "#rotation-table tr[data-entry-kind='activity'][phx-click]")

    render_click(view, "open_shift_coworkers", %{
      "rotation-type" => "daily_assignments",
      "schedule-id" => to_string(ctx.schedule.id),
      "start-date" => "2026-10-05",
      "end-date" => "2026-10-05"
    })

    refute has_element?(view, "#shift-coworkers-modal")
  end

  test "statistics explicitly count rotation days rather than imported tasks", ctx do
    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.iris.id}")

    assert has_element?(view, "#rotation-table", "HH Nights 3rd Call")

    assert has_element?(
             view,
             "div[title='Total scheduled rotation days (excludes vacation)']",
             ~r/Rotation Days\s+14/i
           )

    refute has_element?(view, "p", "Total Shifts")
  end

  test "an activity-only schedule renders even when no rotation date slots exist", ctx do
    ResidencySchedule.Repo.delete_all(ResidencySchedule.Rotations.Rotation)
    assert Rotations.list_schedule_date_slots(ctx.schedule.id) == []

    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.juniper.id}")

    assert has_element?(view, "#rotation-table tbody tr", ~r/HH Nights 3rd Call.*Oct 10, 2026/s)
    refute has_element?(view, "#rotation-table tr[data-rotation-type='off']")
  end

  test "a resident without rotations or activities retains the empty state", ctx do
    {:ok, resident} =
      Residents.insert_resident(ctx.schedule.id, %{
        name: "Hazel Brook",
        position_code: "R2-4",
        residency_year: 2,
        schedule_number: 4
      })

    assert Rotations.list_schedule_date_slots(ctx.schedule.id) != []
    assert DetailedSchedules.list_for_resident(resident.id, ~D[2026-10-10]) == []

    {:ok, view, _html} = live(ctx.conn, "/residents/#{resident.id}")

    assert has_element?(view, "p", "No schedule entries recorded for this resident.")
    refute has_element?(view, "#rotation-table tr[data-rotation-type='off']")
  end

  test "imported notes remain escaped in the main schedule", ctx do
    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.iris.id}")

    assert has_element?(view, "#rotation-table", "<b>literal note</b>")
    refute has_element?(view, "#rotation-table b", "literal note")
  end

  defp off_row(start_date, end_date) do
    "#rotation-table tr[data-rotation-type='off']" <>
      "[phx-value-start-date='#{start_date}'][phx-value-end-date='#{end_date}']"
  end

  defp october_workbook do
    mutate_detail_workbook("xl/sharedStrings.xml", fn xml ->
      Enum.reduce(
        [
          {"December 28, 2026", "October 5, 2026"},
          {"December 29, 2026", "October 6, 2026"},
          {"December 30, 2026", "October 7, 2026"},
          {"December 31, 2026", "October 8, 2026"},
          {"January 1, 2027", "October 9, 2026"},
          {"January 2, 2027", "October 10, 2026"},
          {"January 3, 2027", "October 11, 2026"},
          {"January 4, 2027", "October 12, 2026"},
          {"12/29/2026 Tue", "10/6/2026 Tue"},
          {"GOG Continuity Clinic AM", "HH Nights 3rd Call"},
          {"Bring simulation kit", "Bring simulation kit &lt;b&gt;literal note&lt;/b&gt;"}
        ],
        xml,
        fn {old, new}, content -> String.replace(content, old, new) end
      )
    end)
  end
end
