defmodule ResidencyScheduleWeb.ResidentSpecificRotationsTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest
  import ResidencySchedule.QgendaDetailFixtures

  alias ResidencySchedule.{DetailedSchedules, Residents, Rotations, Schedules, ShiftOverrides}

  doctest ResidencySchedule.DetailedSchedules.TaskEquivalence

  setup :authenticate_session

  setup do
    data = seed_detail_roster()
    {:ok, preview} = detail_preview()
    {:ok, _} = DetailedSchedules.commit(preview, ResidencySchedule.ScheduleFixtures.admin_user())
    data
  end

  for {task, type, base_label} <- [
        {"Vacation", :vacation, "Vacation"},
        {"Ambulatory R4", :ambulatory, "Ambulatory"}
      ] do
    test "#{task} uses the same bounded centered pill style as its base rotation", ctx do
      task = unquote(task)
      type = unquote(type)
      base_label = unquote(base_label)

      workbook =
        mutate_detail_workbook(
          "xl/sharedStrings.xml",
          &String.replace(&1, "SMH GYN R2 Day", task)
        )

      {:ok, preview} = detail_preview(workbook)

      {:ok, _} =
        DetailedSchedules.commit(preview, ResidencySchedule.ScheduleFixtures.admin_user())

      {:ok, _} =
        Rotations.insert_rotations(ctx.iris.id, [
          %{
            slot_index: 1,
            start_date: ~D[2026-12-28],
            end_date: ~D[2027-01-03],
            rotation_type: type
          }
        ])

      {specific_row, base_row} =
        if unquote(type == :vacation) do
          {:ok, _} =
            Rotations.insert_rotations(ctx.iris.id, [
              %{
                slot_index: 2,
                start_date: ~D[2027-01-05],
                end_date: ~D[2027-01-11],
                rotation_type: :vacation
              }
            ])

          {rotation_row(type, "2026-12-28", "2027-01-03"),
           rotation_row(type, "2027-01-05", "2027-01-11")}
        else
          {rotation_row(type, "2026-12-28", "2026-12-29"),
           rotation_row(type, "2026-12-30", "2027-01-03")}
        end

      {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.iris.id}")
      specific_pill = specific_row <> " [data-role='specific-rotation-label']"
      base_pill = base_row <> " span[title='#{base_label}']"
      assert has_element?(view, specific_pill, task)
      assert has_element?(view, base_pill, base_label)
      assert pill_classes(view, specific_pill) == pill_classes(view, base_pill)

      if unquote(type == :vacation) do
        assert has_element?(view, specific_row <> " td:last-child", ~r/^\s*7\s*$/)
        refute has_element?(view, rotation_row(type, "2026-12-28", "2026-12-29"))
        refute has_element?(view, rotation_row(type, "2026-12-30", "2027-01-03"))
      end

      for token <- [
            "w-full",
            "max-w-[11rem]",
            "min-h-8",
            "justify-center",
            "text-center",
            "items-center",
            "whitespace-normal",
            "break-words",
            "px-2"
          ] do
        assert token in pill_classes(view, specific_pill)
      end

      refute "truncate" in pill_classes(view, specific_pill)
      assert has_element?(view, specific_row <> " p", "Coverage discussion")
      refute has_element?(view, specific_pill, "Coverage discussion")
    end
  end

  test "specific tasks replace matching general labels only on their actual dates", ctx do
    before = Rotations.list_rotations_for_resident(ctx.iris.id)
    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.iris.id}")

    for date <- ["2026-12-28", "2026-12-29"] do
      refute has_element?(view, activity_row(date), "SMH GYN R2 Day")
    end

    selector = rotation_row("strong_gynecology", "2026-12-28", "2026-12-29")
    assert has_element?(view, selector, "SMH GYN R2 Day")

    assert has_element?(
             view,
             selector <> " [data-role='specific-rotation-label']",
             "SMH GYN R2 Day"
           )

    refute has_element?(view, selector <> " [data-role='specific-rotation-label'].truncate")

    refute has_element?(
             view,
             selector <> " [data-role='specific-rotation-label'][class*='line-clamp']"
           )

    refute has_element?(view, selector <> " span[title='Gynecology – Strong Memorial']")

    assert has_element?(
             view,
             rotation_row("strong_gynecology", "2026-12-30", "2027-01-03"),
             "Gynecology – Strong Memorial"
           )

    assert has_element?(view, selector, "Coverage discussion")
    assert has_element?(view, activity_row("2026-12-29"), "GOG Continuity Clinic PM")
    assert has_element?(view, activity_row("2026-12-29"), "Bring simulation kit")
    assert has_element?(view, activity_row("2026-12-28"), "Vacation")

    assert has_element?(
             view,
             "div[title='Total scheduled shift days (excludes vacation)']",
             ~r/Total Shifts\s+7/
           )

    assert Rotations.list_rotations_for_resident(ctx.iris.id) == before

    assert Enum.any?(
             DetailedSchedules.list_for_resident(ctx.iris.id, ~D[2026-12-29]),
             &(&1.raw_task == "SMH GYN R2 Day")
           )

    view |> element("#service-filter-toggle") |> render_click()

    view
    |> element("#service-filter-panel button[phx-value-service='strong_gynecology']")
    |> render_click()

    assert has_element?(view, selector, "SMH GYN R2 Day")
    refute has_element?(view, activity_row("2026-12-29"))
  end

  test "specific covered entries keep coverage metadata and use the clipped coworker range",
       ctx do
    [rotation] = Rotations.list_rotations_for_resident(ctx.iris.id)

    {:ok, _} =
      ShiftOverrides.create_override(%{
        rotation_id: rotation.id,
        covering_schedule_resident_id: ctx.juniper.id,
        override_start_date: ~D[2026-12-29],
        override_end_date: ~D[2026-12-29]
      })

    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.iris.id}")
    selector = rotation_row("strong_gynecology", "2026-12-29", "2026-12-29")
    assert has_element?(view, selector, "SMH GYN R2 Day")
    assert has_element?(view, selector, "covered by")
    assert has_element?(view, selector <> " .line-through")
    view |> element(selector) |> render_click()
    assert has_element?(view, "#shift-coworkers-modal")

    assert has_element?(
             view,
             "#rotation-daily-assignments [data-date='2026-12-29']",
             "Coverage discussion"
           )

    refute has_element?(view, "#rotation-daily-assignments [data-date='2026-12-28']")
  end

  test "an older appearance displays later specific assignments in the correct academic year",
       ctx do
    {:ok, prior} = Schedules.upsert_schedule(2025, "2025–2026")

    {:ok, earlier} =
      Residents.insert_resident(prior.id, %{
        name: "Iris Reed",
        resident_id: ctx.iris.resident_id,
        position_code: "R1-1",
        residency_year: 1,
        schedule_number: 1
      })

    {:ok, view, _} = live(ctx.conn, "/residents/#{earlier.id}")

    assert has_element?(
             view,
             rotation_row("strong_gynecology", "2026-12-28", "2026-12-29") <>
               "[phx-value-schedule-id='#{ctx.schedule.id}']",
             "SMH GYN R2 Day"
           )

    refute has_element?(view, activity_row("2026-12-29"), "SMH GYN R2 Day")
  end

  test "daily commitments and its date form are removed while schedule details remain", ctx do
    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.iris.id}")
    refute has_element?(view, "#resident-activity-date-form")
    refute has_element?(view, "#resident-day-activities")
    refute has_element?(view, "h2", "Daily commitments")

    assert has_element?(
             view,
             rotation_row("strong_gynecology", "2026-12-28", "2026-12-29"),
             "Coverage discussion"
           )

    assert has_element?(
             view,
             rotation_row("strong_gynecology", "2026-12-30", "2027-01-03"),
             "Gynecology – Strong Memorial"
           )
  end

  test "multiple specific tasks share one matching rotation row without duplicated activity rows",
       ctx do
    binary =
      mutate_detail_workbook(
        "xl/sharedStrings.xml",
        &String.replace(&1, "SMH GYN R2 Day", "SMH GYN R3 Day")
      )

    {:ok, preview} = detail_preview(binary)
    {:ok, _} = DetailedSchedules.commit(preview, ResidencySchedule.ScheduleFixtures.admin_user())
    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.iris.id}")
    selector = rotation_row("strong_gynecology", "2026-12-28", "2026-12-29")

    for task <- ["SMH GYN R2 Day", "SMH GYN R3 Day"] do
      assert has_element?(view, selector, task)
      refute has_element?(view, "#rotation-table tr[data-entry-kind='activity']", task)
    end

    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query(selector)
           |> Enum.count() == 1
  end

  for {task, type} <- [
        {"HH Weekend 2nd Call", :highland_weekend_days},
        {"HH Weekend 3rd Call", :highland_weekend_days},
        {"HH Weekend Extra", :highland_weekend_days},
        {"HH Nights 2nd Call", :highland_weekend_nights},
        {"HH Nights 3rd Call", :highland_weekend_nights},
        {"HH Nights Extra", :highland_weekend_nights},
        {"HH Nights 2nd Call", :highland_night_float},
        {"HH Nights 3rd Call", :highland_night_float},
        {"HH Nights Extra", :highland_night_float}
      ] do
    test "#{task} replaces #{type} without changing the imported date", ctx do
      task = unquote(task)
      type = unquote(type)

      binary =
        mutate_detail_workbook(
          "xl/sharedStrings.xml",
          &String.replace(&1, "GOG Continuity Clinic AM", task)
        )

      {:ok, preview} = detail_preview(binary)

      {:ok, _} =
        DetailedSchedules.commit(preview, ResidencySchedule.ScheduleFixtures.admin_user())

      {:ok, _} =
        Rotations.insert_rotations(ctx.juniper.id, [
          %{
            slot_index: 1,
            start_date: ~D[2027-01-01],
            end_date: ~D[2027-01-03],
            rotation_type: type
          }
        ])

      {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.juniper.id}")
      assert has_element?(view, rotation_row(type, "2027-01-02", "2027-01-02"), task)
      refute has_element?(view, activity_row("2027-01-02"), task)

      assert has_element?(
               view,
               rotation_row(type, "2027-01-01", "2027-01-01"),
               Rotations.rotation_type_label(to_string(type))
             )

      assert has_element?(
               view,
               rotation_row(type, "2027-01-03", "2027-01-03"),
               Rotations.rotation_type_label(to_string(type))
             )
    end
  end

  defp rotation_row(type, first, last),
    do:
      "#rotation-table tr[data-rotation-type='#{type}'][phx-value-start-date='#{first}'][phx-value-end-date='#{last}']"

  defp activity_row(date),
    do: "#rotation-table tr[data-entry-kind='activity'][data-date='#{date}']"

  defp pill_classes(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("class")
    |> Enum.flat_map(&String.split/1)
    |> Enum.sort()
  end
end
