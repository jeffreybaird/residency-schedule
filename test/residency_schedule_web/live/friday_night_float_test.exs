defmodule ResidencyScheduleWeb.FridayNightFloatTest do
  use ResidencyScheduleWeb.ConnCase

  import Phoenix.LiveViewTest

  alias ResidencySchedule.{
    Assistant,
    DetailedSchedules,
    Repo,
    Residents,
    Rotations,
    Schedules,
    ShiftOverrides
  }

  alias ResidencySchedule.DetailedSchedules.{Activity, ActivitySource, ImportBatch}

  doctest ResidencySchedule.Rotations.FridayNightFloat

  @friday ~D[2026-10-09]

  setup :authenticate_session

  setup do
    {:ok, schedule} = Schedules.upsert_schedule(2026, "2026–2027")

    people =
      [
        {:alder, "Alder", :ambulatory},
        {:birch, "Birch", :ambulatory},
        {:cedar, "Cedar", :night_float},
        {:dogwood, "Dogwood", :night_float},
        {:elm, "Elm", :highland_night_float},
        {:fern, "Fern", :night_float},
        {:hazel, "Hazel", :elective}
      ]
      |> Enum.with_index(1)
      |> Map.new(fn {{key, name, type}, number} ->
        {:ok, resident} =
          Residents.insert_resident(schedule.id, %{
            name: name,
            position_code: "R2-#{number}",
            residency_year: 2,
            schedule_number: number
          })

        insert_rotation(resident, type, ~D[2026-10-05], ~D[2026-10-11])
        {key, resident}
      end)

    admin = ResidencySchedule.ScheduleFixtures.admin_user()

    batch =
      Repo.insert!(%ImportBatch{
        schedule_id: schedule.id,
        created_by_id: admin.id,
        fingerprint: Ecto.UUID.generate(),
        header_start: ~D[2026-10-05],
        header_end: ~D[2026-10-11]
      })

    Map.merge(people, %{schedule: schedule, batch: batch})
  end

  for rank <- ["1st", "2nd", "3rd", "4th"] do
    test "one Ambulatory #{rank} Contact Night assignment corrects Friday for the whole usual Strong team",
         ctx do
      task = "SMH Obstetrics Resident #{unquote(rank)} Contact Night"
      add_activity(ctx, ctx.alder, @friday, task)
      raw = Rotations.list_rotations_for_resident(ctx.alder.id)
      source = DetailedSchedules.list_for_resident(ctx.alder.id, @friday)

      assert spans(ctx.alder) == [
               {"ambulatory", ~D[2026-10-05], ~D[2026-10-08]},
               {"strong_weekend_nights", @friday, @friday},
               {"ambulatory", ~D[2026-10-10], ~D[2026-10-11]}
             ]

      for resident <- [ctx.cedar, ctx.dogwood, ctx.fern] do
        assert spans(resident) == [
                 {"night_float", ~D[2026-10-05], ~D[2026-10-08]},
                 {"post_call", @friday, @friday},
                 {"night_float", ~D[2026-10-10], ~D[2026-10-11]}
               ]
      end

      assert spans(ctx.birch) == [{"ambulatory", ~D[2026-10-05], ~D[2026-10-11]}]
      assert spans(ctx.elm) == [{"highland_night_float", ~D[2026-10-05], ~D[2026-10-11]}]
      assert Rotations.list_rotations_for_resident(ctx.alder.id) == raw
      assert DetailedSchedules.list_for_resident(ctx.alder.id, @friday) == source
    end
  end

  test "non-Friday, wrong task, unknown contact rank and non-Ambulatory sources do not trigger correction",
       ctx do
    for {resident, date, task} <- [
          {ctx.alder, ~D[2026-10-08], "SMH Obstetrics Resident 1st Contact Night"},
          {ctx.alder, @friday, "SMH Gynecology Chief On Call Night"},
          {ctx.alder, @friday, "SMH Obstetrics Resident 1st Contact Day"},
          {ctx.alder, @friday, "SMH Obstetrics Resident 5th Contact Night"},
          {ctx.alder, @friday, "HH Nights 3rd Call"},
          {ctx.hazel, @friday, "SMH Obstetrics Resident 2nd Contact Night"}
        ] do
      add_activity(ctx, resident, date, task)
    end

    assert spans(ctx.alder) == [{"ambulatory", ~D[2026-10-05], ~D[2026-10-11]}]
    assert spans(ctx.cedar) == [{"night_float", ~D[2026-10-05], ~D[2026-10-11]}]
  end

  test "explicit same-day night duty and approved coverage take precedence over the usual-team correction",
       ctx do
    add_activity(ctx, ctx.alder, @friday, "SMH Obstetrics Resident 1st Contact Night")
    add_activity(ctx, ctx.fern, @friday, "SMH Obstetrics Resident 4th Contact Night")
    [rotation] = Rotations.list_rotations_for_resident(ctx.cedar.id)

    {:ok, _} =
      ShiftOverrides.create_override(%{
        rotation_id: rotation.id,
        covering_schedule_resident_id: ctx.hazel.id,
        override_start_date: @friday,
        override_end_date: @friday
      })

    assert day_type(ctx.fern, @friday) == "night_float"
    assert day_type(ctx.dogwood, @friday) == "post_call"

    cedar =
      Enum.find(
        Rotations.effective_segments_for_resident(ctx.cedar.id),
        &(&1.start_date == @friday)
      )

    assert cedar.rotation_type == "night_float"
    assert cedar.covered_by.id == ctx.hazel.id

    assert Enum.any?(
             Rotations.effective_segments_for_resident(ctx.hazel.id),
             &(&1.is_coverage and &1.rotation_type == "night_float" and &1.start_date == @friday)
           )
  end

  test "projection is scoped to schedule identity and removal of evidence restores the unsplit block",
       ctx do
    activity = add_activity(ctx, ctx.alder, @friday, "SMH Obstetrics Resident 1st Contact Night")
    {:ok, other_schedule} = Schedules.upsert_schedule(2025, "2025–2026")

    {:ok, other} =
      Residents.insert_resident(other_schedule.id, %{
        name: "Alder",
        resident_id: ctx.alder.resident_id,
        position_code: "R1-1",
        residency_year: 1,
        schedule_number: 1
      })

    # Deliberately overlapping dates exercise schedule identity independently of date matching.
    insert_rotation(other, :night_float, ~D[2026-10-05], ~D[2026-10-11])
    assert day_type(other, @friday) == "night_float"
    assert day_type(ctx.alder, @friday) == "strong_weekend_nights"
    Repo.delete!(activity)
    assert spans(ctx.alder) == [{"ambulatory", ~D[2026-10-05], ~D[2026-10-11]}]
    assert spans(ctx.cedar) == [{"night_float", ~D[2026-10-05], ~D[2026-10-11]}]
  end

  test "calendar and resident details use full schedule evidence even after resident filtering",
       ctx do
    add_activity(ctx, ctx.alder, @friday, "SMH Obstetrics Resident 1st Contact Night")
    {:ok, calendar, _} = live(ctx.conn, "/calendar?view=day&date=2026-10-09")
    assert has_element?(calendar, calendar_person("strong_weekend_nights", ctx.alder))
    assert has_element?(calendar, calendar_person("post_call", ctx.cedar))
    assert has_element?(calendar, calendar_person("ambulatory", ctx.birch))
    render_click(calendar, "toggle_resident_filter", %{"id" => to_string(ctx.cedar.resident_id)})
    assert has_element?(calendar, calendar_person("post_call", ctx.cedar))
    refute has_element?(calendar, "#day-activities [data-resident-id='#{ctx.alder.resident_id}']")

    {:ok, resident, _} = live(ctx.conn, "/residents/#{ctx.alder.id}")

    selector =
      "#rotation-table tr[data-rotation-type='strong_weekend_nights'][phx-value-start-date='2026-10-09'][phx-value-end-date='2026-10-09']"

    assert has_element?(resident, selector, "SMH Obstetrics Resident 1st Contact Night")
    resident |> form("#resident-activity-date-form", %{"date" => "2026-10-09"}) |> render_change()
    refute has_element?(resident, "#resident-day-activities", "Base rotation: Ambulatory")

    {:ok, usual, _} = live(ctx.conn, "/residents/#{ctx.cedar.id}")
    usual |> form("#resident-activity-date-form", %{"date" => "2026-10-09"}) |> render_change()
    assert has_element?(usual, "#resident-day-activities", "Post Call")
    render_click(usual, "toggle_night_shifts", %{})
    assert has_element?(usual, "div", ~r/Night Float – Strong\s+6 days/)

    assert has_element?(
             usual,
             "#sticky-stats",
             ~r/Total Shifts\s+6/
           )
  end

  test "coworkers, Assistant and subscribed calendars agree about Friday", ctx do
    add_activity(ctx, ctx.alder, @friday, "SMH Obstetrics Resident 1st Contact Night")

    coworkers =
      Rotations.list_effective_coworker_rows_for_type_in_range(
        ctx.schedule.id,
        "strong_weekend_nights",
        @friday,
        @friday
      )

    assert Enum.map(coworkers, & &1.resident.id) == [ctx.alder.id]
    assert {:ok, answer} = Assistant.who_is_on("strong weekend nights", "2026-10-09")

    assert Enum.map(answer.assignments, &{&1.name, &1.position_code, &1.rotation_type}) ==
             [{ctx.alder.name, ctx.alder.position_code, "strong_weekend_nights"}]

    for {resident, label} <- [{ctx.alder, "Weekend Nights – Strong"}, {ctx.cedar, "Post Call"}] do
      body = ctx.conn |> get("/residents/#{resident.id}/calendar.ics") |> response(200)

      event =
        body
        |> String.split("BEGIN:VEVENT")
        |> Enum.find(&String.contains?(&1, "SUMMARY:#{label}"))

      assert event, "missing #{label} event"
      assert event =~ "20261009"

      if resident.id == ctx.alder.id do
        assert event =~ "DTSTART:20261009T180000"
        assert event =~ "DTEND:20261010T060000"
      end
    end

    original = ctx.conn |> get("/residents/#{ctx.cedar.id}/calendar.ics") |> response(200)
    assert original =~ "DTSTART:20261004T180000"
    assert original =~ "DTEND:20261005T060000"
  end

  test "existing Post Call days are excluded from resident working-day statistics", ctx do
    insert_rotation(ctx.hazel, :post_call, ~D[2026-10-12], ~D[2026-10-13])
    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.hazel.id}")

    assert has_element?(
             view,
             "#sticky-stats",
             ~r/Total Shifts\s+7/
           )

    refute has_element?(
             view,
             "#sticky-stats",
             ~r/Total Shifts\s+9/
           )
  end

  test "the read-only schedule grid shows corrected Friday pills and exact detail dates", ctx do
    add_activity(ctx, ctx.alder, @friday, "SMH Obstetrics Resident 1st Contact Night")
    [ambulatory] = Rotations.list_rotations_for_resident(ctx.alder.id)
    [night_float] = Rotations.list_rotations_for_resident(ctx.cedar.id)
    {:ok, view, _} = live(ctx.conn, "/schedule")

    promoted =
      "button[data-rotation-id='#{ambulatory.id}'][aria-label='View Weekend Nights – Strong details']"

    assert has_element?(view, promoted, "SWN")

    assert has_element?(
             view,
             "button[data-rotation-id='#{night_float.id}'][aria-label='View Post Call details']"
           )

    view |> element(promoted) |> render_click()
    assert has_element?(view, "#gantt-rotation-modal-title", "Alder")

    assert has_element?(
             view,
             "#gantt-rotation-dates[data-start-date='2026-10-09'][data-end-date='2026-10-09']"
           )

    assert has_element?(
             view,
             "#gantt-daily-assignments",
             "SMH Obstetrics Resident 1st Contact Night"
           )

    assert Rotations.list_rotations_for_resident(ctx.alder.id) == [ambulatory]
  end

  test "the Friday imported night wins an identical Strong weekend event without dropping Thursday or another site",
       ctx do
    [original] = Rotations.list_rotations_for_resident(ctx.alder.id)
    Repo.delete!(original)
    insert_rotation(ctx.alder, :ambulatory, ~D[2026-10-05], @friday)
    insert_rotation(ctx.alder, :strong_weekend_nights, ~D[2026-10-10], ~D[2026-10-10])
    insert_rotation(ctx.alder, :highland_night_float, ~D[2026-10-10], ~D[2026-10-10])
    add_activity(ctx, ctx.alder, @friday, "SMH Obstetrics Resident 1st Contact Night")
    body = ctx.conn |> get("/residents/#{ctx.alder.id}/calendar.ics") |> response(200)

    events =
      body
      |> String.split("BEGIN:VEVENT")
      |> Enum.filter(&String.contains?(&1, "DTSTART:20261009T180000"))

    assert length(events) == 2
    assert Enum.count(events, &String.contains?(&1, "SUMMARY:Weekend Nights – Strong")) == 1
    assert Enum.count(events, &String.contains?(&1, "SUMMARY:Night Float – Highland")) == 1
    refute Enum.any?(events, &String.contains?(&1, "SUMMARY:Night Float – Strong"))
    assert Enum.all?(events, &String.contains?(&1, "DTEND:20261010T060000"))
    assert body =~ "DTSTART:20261008T060000"
    assert body =~ "DTEND:20261008T180000"
  end

  test "Nov 2–19 transition renders actual night dates and exports both weekend nights before Monday ambulatory",
       ctx do
    [original] = Rotations.list_rotations_for_resident(ctx.alder.id)
    Repo.delete!(original)

    for {type, first, last} <- [
          {:ambulatory, ~D[2026-11-02], ~D[2026-11-06]},
          {:strong_weekend_nights, ~D[2026-11-07], ~D[2026-11-08]},
          {:ambulatory, ~D[2026-11-09], ~D[2026-11-13]},
          {:strong_weekend_nights, ~D[2026-11-14], ~D[2026-11-15]},
          {:night_float, ~D[2026-11-16], ~D[2026-11-20]}
        ] do
      insert_rotation(ctx.alder, type, first, last)
    end

    body = ctx.conn |> get("/residents/#{ctx.alder.id}/calendar.ics") |> response(200)

    events = String.split(body, "BEGIN:VEVENT")

    for {label, start_time, end_time} <- [
          {"Weekend Nights – Strong", "20261106T180000", "20261107T060000"},
          {"Weekend Nights – Strong", "20261107T180000", "20261108T060000"},
          {"Weekend Nights – Strong", "20261113T180000", "20261114T060000"},
          {"Weekend Nights – Strong", "20261114T180000", "20261115T060000"},
          {"Night Float – Strong", "20261115T180000", "20261116T060000"},
          {"Night Float – Strong", "20261119T180000", "20261120T060000"},
          {"Ambulatory", "20261109T060000", "20261109T180000"}
        ] do
      assert Enum.count(events, fn event ->
               String.contains?(event, "SUMMARY:#{label}") and
                 String.contains?(event, "DTSTART:#{start_time}") and
                 String.contains?(event, "DTEND:#{end_time}")
             end) == 1
    end

    refute Enum.any?(events, fn event ->
             String.contains?(event, "SUMMARY:Weekend Nights – Strong") and
               String.contains?(event, "DTSTART:20261108T180000")
           end)

    {:ok, calendar, _} = live(ctx.conn, "/calendar?view=day&date=2026-11-06")
    assert has_element?(calendar, calendar_person("strong_weekend_nights", ctx.alder))
    refute has_element?(calendar, calendar_person("ambulatory", ctx.alder))

    {:ok, sunday, _} = live(ctx.conn, "/calendar?view=day&date=2026-11-15")
    assert has_element?(sunday, calendar_person("night_float", ctx.alder))
    refute has_element?(sunday, calendar_person("strong_weekend_nights", ctx.alder))

    {:ok, monday, _} = live(ctx.conn, "/calendar?view=day&date=2026-11-09")
    assert has_element?(monday, calendar_person("ambulatory", ctx.alder))

    {:ok, resident, _} = live(ctx.conn, "/residents/#{ctx.alder.id}")

    assert has_element?(
             resident,
             "#rotation-table tr[data-rotation-type='strong_weekend_nights'][phx-value-start-date='2026-11-06'][phx-value-end-date='2026-11-07']"
           )

    assert has_element?(
             resident,
             "#rotation-table tr[data-rotation-type='night_float'][phx-value-start-date='2026-11-15'][phx-value-end-date='2026-11-19']"
           )
  end

  defp calendar_person(type, resident),
    do:
      "#day-activities [data-rotation-type='#{type}'] [data-resident-id='#{resident.resident_id}']"

  defp spans(resident),
    do:
      resident.id
      |> Rotations.effective_segments_for_resident()
      |> Enum.map(&{&1.rotation_type, &1.start_date, &1.end_date})

  defp day_type(resident, date),
    do:
      resident.id
      |> Rotations.effective_segments_for_resident()
      |> Enum.find(&(date in Date.range(&1.start_date, &1.end_date)))
      |> Map.fetch!(:rotation_type)

  defp insert_rotation(resident, type, first, last),
    do:
      Rotations.insert_rotations(resident.id, [
        %{slot_index: 0, start_date: first, end_date: last, rotation_type: type}
      ])

  defp add_activity(ctx, resident, date, task) do
    activity =
      Repo.insert!(%Activity{schedule_resident_id: resident.id, date: date, raw_task: task})

    Repo.insert!(%ActivitySource{
      activity_id: activity.id,
      batch_id: ctx.batch.id,
      source_sheet: "Synthetic",
      source_cell: "A#{activity.id}",
      raw_staff: resident.name,
      display_name: resident.name,
      previous_name: resident.name
    })

    activity
  end
end
