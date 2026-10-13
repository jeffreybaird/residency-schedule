defmodule ResidencyScheduleWeb.QgendaScheduleGapsTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest

  alias ResidencySchedule.{
    Assistant,
    DetailedSchedules,
    Repo,
    Residents,
    Rotations,
    ScheduleBuilder,
    Schedules,
    ShiftOverrides
  }

  alias ResidencySchedule.DetailedSchedules.{Activity, ActivitySource, ImportBatch}
  alias ResidencySchedule.Rotations.ScheduleGaps

  doctest ResidencySchedule.Rotations.ScheduleGaps

  setup :authenticate_session

  setup do
    {:ok, schedule} = Schedules.upsert_schedule(2026, "2026–2027")

    {:ok, iris} =
      Residents.insert_resident(schedule.id, %{
        name: "Iris Reed",
        position_code: "R2-1",
        residency_year: 2,
        schedule_number: 1
      })

    {:ok, juniper} =
      Residents.insert_resident(schedule.id, %{
        name: "Juniper Vale",
        position_code: "R2-2",
        residency_year: 2,
        schedule_number: 2
      })

    for {resident, type} <- [{iris, :rei}, {juniper, :vacation}] do
      {:ok, _} =
        Rotations.insert_rotations(resident.id, [
          %{
            slot_index: 0,
            start_date: ~D[2026-10-05],
            end_date: ~D[2026-10-09],
            rotation_type: type
          }
        ])
    end

    batch =
      Repo.insert!(%ImportBatch{
        schedule_id: schedule.id,
        created_by_id: ResidencySchedule.ScheduleFixtures.admin_user().id,
        fingerprint: Ecto.UUID.generate(),
        header_start: ~D[2026-10-05],
        header_end: ~D[2026-10-12]
      })

    %{schedule: schedule, iris: iris, juniper: juniper, batch: batch}
  end

  test "weekend vacation fills raw gaps without changing storage or editor assignments", ctx do
    raw = Rotations.list_rotations_for_resident(ctx.juniper.id)
    {:ok, editor} = ScheduleBuilder.load_from_schedule(ctx.schedule.id)

    for date <- [~D[2026-10-10], ~D[2026-10-11]],
        do: add_activity(ctx, ctx.juniper, date, "Vacation")

    source = DetailedSchedules.list_for_resident(ctx.juniper.id, ~D[2026-10-10])

    for date <- [~D[2026-10-10], ~D[2026-10-11]] do
      assert types_on(ctx.juniper, date) == ["vacation"]
      assert Enum.all?(projected_on(ctx.juniper, date), &is_nil(&1.id))
    end

    assert types_on(ctx.juniper, ~D[2026-10-12]) == []
    assert Rotations.list_rotations_for_resident(ctx.juniper.id) == raw
    assert {:ok, unchanged_editor} = ScheduleBuilder.load_from_schedule(ctx.schedule.id)
    assert unchanged_editor.assignments == editor.assignments
    assert unchanged_editor.slots == editor.slots
    refute "qgenda_assignment" in Rotations.all_rotation_types()
    assert DetailedSchedules.list_for_resident(ctx.juniper.id, ~D[2026-10-10]) == source
  end

  test "known duties fill gaps while raw base rotations retain precedence", ctx do
    add_activity(ctx, ctx.iris, ~D[2026-10-10], "REI Resident", ["Bring supplies"])
    add_activity(ctx, ctx.juniper, ~D[2026-10-10], "HH Nights 3rd Call")
    add_activity(ctx, ctx.iris, ~D[2026-10-09], "Vacation")
    assert types_on(ctx.iris, ~D[2026-10-10]) == ["rei"]
    assert types_on(ctx.juniper, ~D[2026-10-10]) == ["highland_weekend_nights"]
    assert types_on(ctx.iris, ~D[2026-10-09]) == ["rei"]

    for type <- [:highland_weekend_nights, :strong_weekend_nights] do
      {:ok, _} =
        Rotations.insert_rotations(ctx.juniper.id, [
          %{
            slot_index: 1,
            start_date: ~D[2026-10-11],
            end_date: ~D[2026-10-11],
            rotation_type: type
          }
        ])
    end

    night_feed = ctx.conn |> get("/residents/#{ctx.juniper.id}/calendar.ics") |> response(200)
    assert night_feed =~ "DTSTART:20261010T180000"
    assert night_feed =~ "DTEND:20261011T060000"

    night_events =
      night_feed
      |> String.split("BEGIN:VEVENT")
      |> Enum.filter(&String.contains?(&1, "DTSTART:20261010T180000"))

    assert length(night_events) == 2
    assert Enum.count(night_events, &String.contains?(&1, "HH Nights 3rd Call")) == 1
    assert Enum.count(night_events, &String.contains?(&1, "SUMMARY:Weekend Nights – Strong")) == 1

    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.iris.id}")
    assert has_element?(view, "#rotation-table tr[data-rotation-type='rei']", "REI Resident")
    assert has_element?(view, "#rotation-table", "Bring supplies")
    assert has_element?(view, "#sticky-stats", ~r/Total Shifts\s+6/)

    assert has_element?(
             view,
             "#rotation-table tr[data-entry-kind='activity'][data-date='2026-10-09']",
             "Vacation"
           )
  end

  test "same-type tasks share one day and unknown or ambiguous items stay literal and untimed",
       ctx do
    for task <- [
          "HH GYN R1",
          "HH GYN R2",
          "REI Resident",
          "Mystery Clinic PM",
          "SMH Obstetrics Resident 1st Contact Night"
        ] do
      add_activity(ctx, ctx.iris, ~D[2026-10-10], task, ["Keep <b>literal</b> notes"])
    end

    assert Enum.sort(types_on(ctx.iris, ~D[2026-10-10])) == [
             "highland_gynecology",
             "qgenda_assignment",
             "rei"
           ]

    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.iris.id}")

    for task <- [
          "HH GYN R1",
          "HH GYN R2",
          "REI Resident",
          "Mystery Clinic PM",
          "SMH Obstetrics Resident 1st Contact Night"
        ] do
      assert has_element?(view, "#rotation-table", task)
    end

    assert has_element?(view, "#rotation-table", "Keep <b>literal</b> notes")
    refute has_element?(view, "#rotation-table b", "literal")
    assert has_element?(view, "#sticky-stats", ~r/Total Shifts\s+6/)

    assert {:ok, %{count: 1, by_rotation: by_rotation}} =
             Assistant.shifts_remaining(ctx.iris.name, "2026-10-10", "2026-10-10")

    assert Map.new(by_rotation, &{&1.rotation_type, &1.days}) == %{
             "highland_gynecology" => 1,
             "rei" => 1
           }

    body = ctx.conn |> get("/residents/#{ctx.iris.id}/calendar.ics") |> response(200)

    unknown =
      body
      |> String.split("BEGIN:VEVENT")
      |> Enum.find(&String.contains?(&1, "Mystery Clinic PM"))

    assert unknown
    assert unknown =~ "DTSTART;VALUE=DATE:20261010"
    assert unknown =~ "SMH Obstetrics Resident 1st Contact Night"
    refute unknown =~ "DTSTART:20261010T"
  end

  test "approved coverage fills the date before imported fallback and source remains available",
       ctx do
    {:ok, _} =
      Rotations.insert_rotations(ctx.juniper.id, [
        %{
          slot_index: 1,
          start_date: ~D[2026-10-10],
          end_date: ~D[2026-10-10],
          rotation_type: :oncology
        }
      ])

    rotation =
      Rotations.list_rotations_for_resident(ctx.juniper.id)
      |> Enum.find(&(&1.rotation_type == "oncology"))

    {:ok, _} =
      ShiftOverrides.create_override(%{
        rotation_id: rotation.id,
        covering_schedule_resident_id: ctx.iris.id,
        override_start_date: ~D[2026-10-10],
        override_end_date: ~D[2026-10-10]
      })

    add_activity(ctx, ctx.iris, ~D[2026-10-10], "Vacation")

    entries =
      Rotations.effective_segments_for_resident(ctx.iris.id)
      |> Enum.filter(&(~D[2026-10-10] in Date.range(&1.start_date, &1.end_date)))

    assert [%{rotation_type: "oncology", is_coverage: true}] = entries

    assert [%{raw_task: "Vacation"}] =
             DetailedSchedules.list_for_resident(ctx.iris.id, ~D[2026-10-10])
  end

  test "fallback stays attached to its resident and academic-year appearance", ctx do
    add_activity(ctx, ctx.juniper, ~D[2026-10-10], "Vacation")
    {:ok, prior} = Schedules.upsert_schedule(2025, "2025–2026")

    {:ok, older} =
      Residents.insert_resident(prior.id, %{
        name: "Juniper Vale",
        resident_id: ctx.juniper.resident_id,
        position_code: "R1-2",
        residency_year: 1,
        schedule_number: 2
      })

    assert projected_on(older, ~D[2026-10-10]) == []
    assert projected_on(ctx.iris, ~D[2026-10-10]) == []
    assert types_on(ctx.juniper, ~D[2026-10-10]) == ["vacation"]
    {:ok, view, _} = live(ctx.conn, "/residents/#{older.id}")
    assert has_element?(view, "#rotation-table", "Vacation")
    assert has_element?(view, "#rotation-table", "Oct 10, 2026")
  end

  test "calendar, resident, grid, Assistant, coworkers and ICS expose the same filled day", ctx do
    ctx.juniper.id |> Rotations.list_rotations_for_resident() |> Enum.each(&Repo.delete!/1)
    assert Rotations.list_rotations_for_resident(ctx.juniper.id) == []
    add_activity(ctx, ctx.juniper, ~D[2026-10-10], "Vacation")
    add_activity(ctx, ctx.iris, ~D[2026-10-10], "REI Resident")

    for mode <- ["day", "month", "week"] do
      {:ok, view, _} = live(ctx.conn, "/calendar?view=#{mode}&date=2026-10-10")

      if mode != "day",
        do:
          view
          |> element("[phx-click='select_day'][phx-value-date='2026-10-10']")
          |> render_click()

      assert has_element?(
               view,
               "#day-activities [data-rotation-type='vacation'] [data-resident-id='#{ctx.juniper.resident_id}']"
             )

      assert has_element?(
               view,
               "#day-activities [data-rotation-type='rei'] [data-resident-id='#{ctx.iris.resident_id}']"
             )
    end

    {:ok, resident, _} = live(ctx.conn, "/residents/#{ctx.juniper.id}")

    assert has_element?(
             resident,
             "#rotation-table tr[data-rotation-type='vacation']",
             "Oct 10, 2026"
           )

    refute has_element?(resident, "#rotation-table tr[data-rotation-type='off']", "Oct 10, 2026")
    assert has_element?(resident, "#sticky-stats", ~r/Total Shifts\s+0/)
    {:ok, grid, _} = live(ctx.conn, "/schedule")
    assert has_element?(grid, "button[aria-label='View Vacation details']")
    assert {:ok, answer} = Assistant.who_is_on("rei", "2026-10-10")
    assert Enum.map(answer.assignments, & &1.name) == [ctx.iris.name]

    assert [%{resident: %{id: id}}] =
             Rotations.list_effective_coworker_rows_for_type_in_range(
               ctx.schedule.id,
               "rei",
               ~D[2026-10-10],
               ~D[2026-10-10]
             )

    assert id == ctx.iris.id
    body = ctx.conn |> get("/residents/#{ctx.juniper.id}/calendar.ics") |> response(200)

    assert Enum.any?(
             String.split(body, "BEGIN:VEVENT"),
             &(String.contains?(&1, "SUMMARY:Vacation") and
                 String.contains?(&1, "DTSTART;VALUE=DATE:20261010"))
           )
  end

  defp projected_on(resident, date),
    do:
      resident.id
      |> Rotations.projected_rotations_for_resident()
      |> Enum.filter(&(date in Date.range(&1.start_date, &1.end_date)))

  test "gap projections sort chronologically across month and year boundaries" do
    dates = [~D[2027-01-01], ~D[2026-12-31], ~D[2026-11-30], ~D[2026-12-01]]

    activities =
      Enum.map(
        dates,
        &%{schedule_resident_id: 7, schedule_resident: %{id: 7}, date: &1, raw_task: "Vacation"}
      )

    result = ScheduleGaps.project([], activities, [])

    assert Enum.map(result, & &1.start_date) == [
             ~D[2026-11-30],
             ~D[2026-12-01],
             ~D[2026-12-31],
             ~D[2027-01-01]
           ]
  end

  test "imported Saturday vacation keeps its full all-day interval before a Sunday legacy night",
       ctx do
    add_activity(ctx, ctx.juniper, ~D[2026-10-10], "Vacation")

    {:ok, _} =
      Rotations.insert_rotations(ctx.juniper.id, [
        %{
          slot_index: 1,
          start_date: ~D[2026-10-11],
          end_date: ~D[2026-10-11],
          rotation_type: :highland_weekend_nights
        }
      ])

    body = ctx.conn |> get("/residents/#{ctx.juniper.id}/calendar.ics") |> response(200)

    event =
      body
      |> String.split("BEGIN:VEVENT")
      |> Enum.find(
        &(String.contains?(&1, "SUMMARY:Vacation") and
            String.contains?(&1, "DTSTART;VALUE=DATE:20261010"))
      )

    assert event
    assert event =~ "DTEND;VALUE=DATE:20261011"
    refute event =~ "DTEND;VALUE=DATE:20261010"
  end

  test "neutral gap items keep unique grid details and escaped untimed exports", ctx do
    task = "Mystery; Clinic, PM\\North\nSecond line"
    add_activity(ctx, ctx.iris, ~D[2026-10-10], task, ["Private instruction"])
    add_activity(ctx, ctx.iris, ~D[2026-10-11], "Other Mystery")
    {:ok, grid, _} = live(ctx.conn, "/schedule")

    grid
    |> element("button[phx-click='open_rotation_details']", "Other Mystery")
    |> render_click()

    assert has_element?(grid, "#gantt-rotation-modal-title", ctx.iris.name)

    assert has_element?(
             grid,
             "#gantt-rotation-dates[data-start-date='2026-10-11'][data-end-date='2026-10-11']"
           )

    assert has_element?(grid, "#gantt-daily-assignments", "Other Mystery")
    refute has_element?(grid, "#gantt-daily-assignments", "Private instruction")
    refute has_element?(grid, "#gantt-rotation-modal [phx-click='edit_assignment']")

    assert Rotations.list_effective_coworker_rows_for_type_in_range(
             ctx.schedule.id,
             "qgenda_assignment",
             ~D[2026-10-10],
             ~D[2026-10-11]
           ) == []

    body = ctx.conn |> get("/residents/#{ctx.iris.id}/calendar.ics") |> response(200)
    assert body =~ "SUMMARY:Mystery\\; Clinic\\, PM\\\\North\\nSecond line"
    assert body =~ "DTSTART;VALUE=DATE:20261010"
    assert body =~ "DTSTART;VALUE=DATE:20261011"
    refute body =~ "SUMMARY:Mystery; Clinic, PM\\North\nSecond line"
  end

  defp types_on(resident, date),
    do: resident |> projected_on(date) |> Enum.map(& &1.rotation_type)

  defp add_activity(ctx, resident, date, task, notes \\ []) do
    activity =
      Repo.insert!(%Activity{schedule_resident_id: resident.id, date: date, raw_task: task})

    Repo.insert!(%ActivitySource{
      activity_id: activity.id,
      batch_id: ctx.batch.id,
      source_sheet: "Synthetic",
      source_cell: "A#{activity.id}",
      raw_staff: resident.name,
      display_name: resident.name,
      previous_name: resident.name,
      notes:
        Enum.map(
          notes,
          &%{"text" => &1, "source_sheet" => "Synthetic", "source_cell" => "A#{activity.id}"}
        )
    })

    activity
  end
end
