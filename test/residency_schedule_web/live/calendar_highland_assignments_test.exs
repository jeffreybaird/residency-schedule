defmodule ResidencyScheduleWeb.CalendarHighlandAssignmentsTest do
  use ResidencyScheduleWeb.ConnCase

  import Phoenix.LiveViewTest
  import ResidencySchedule.QgendaDetailFixtures

  alias ResidencySchedule.{DetailedSchedules, Rotations, ShiftOverrides}

  @night_type "highland_weekend_nights"
  @label "Weekend Nights – Highland"
  @day "2026-10-10"

  setup :authenticate_session

  setup do
    seed_detail_roster()
  end

  test "each approved Saturday task appears under Highland weekend nights in day and modal views",
       ctx do
    for task <- ["HH Nights 2nd Call", "HH Nights 3rd Call", "HH Nights Extra"] do
      import_task(task)

      for mode <- ["day", "month"] do
        {:ok, view, _} = live(ctx.conn, "/calendar?view=#{mode}&date=#{@day}")
        if mode == "month", do: open_day(view)

        assert has_element?(view, group() <> " > h3", @label)
        assert has_element?(view, group() <> " > h3", "1 resident")
        assert has_element?(view, person(ctx.juniper), task)

        assert has_element?(
                 view,
                 person(ctx.juniper) <> " a[href='/residents/#{ctx.juniper.id}']"
               )
      end

      activities = DetailedSchedules.list_for_resident(ctx.juniper.id, ~D[2026-10-10])
      assert Enum.any?(activities, &(&1.raw_task == task and &1.date == ~D[2026-10-10]))
      assert Rotations.list_rotations_for_resident(ctx.juniper.id) == []
    end
  end

  test "month dots, weekly unique counts, and filter options include imported Saturday nights",
       ctx do
    import_task("HH Nights 3rd Call")
    {:ok, month, _} = live(ctx.conn, "/calendar?view=month&date=#{@day}")
    assert has_element?(month, day_cell() <> " span[title='#{@label}']")
    render_click(month, "toggle_resident_filter", %{"id" => to_string(ctx.iris.resident_id)})
    refute has_element?(month, day_cell() <> " span[title='#{@label}']")
    render_click(month, "toggle_resident_filter", %{"id" => to_string(ctx.iris.resident_id)})
    render_click(month, "toggle_resident_filter", %{"id" => to_string(ctx.juniper.resident_id)})
    assert has_element?(month, day_cell() <> " span[title='#{@label}']")

    {:ok, week, _} = live(ctx.conn, "/calendar?view=week&date=#{@day}")
    assert has_element?(week, day_cell(), @label)
    assert has_element?(week, day_cell() <> " .font-mono", "1")

    render_click(week, "toggle_filter_panel", %{"panel" => "rotations"})

    assert has_element?(
             week,
             "button[phx-click='toggle_rotation_filter'][phx-value-type='#{@night_type}']",
             @label
           )

    render_click(week, "toggle_rotation_filter", %{"type" => @night_type})
    open_day(week)
    assert has_element?(week, person(ctx.juniper), "HH Nights 3rd Call")

    render_click(week, "toggle_resident_filter", %{"id" => to_string(ctx.iris.resident_id)})
    refute has_element?(week, day_cell(), @label)
    refute has_element?(week, group())
    refute has_element?(week, "#day-activities [data-resident-id='#{ctx.juniper.resident_id}']")
    render_click(week, "toggle_resident_filter", %{"id" => to_string(ctx.iris.resident_id)})
    render_click(week, "toggle_resident_filter", %{"id" => to_string(ctx.juniper.resident_id)})
    assert has_element?(week, day_cell() <> " .font-mono", "1")
    assert has_element?(week, person(ctx.juniper), "HH Nights 3rd Call")

    render_click(week, "toggle_rotation_filter", %{"type" => @night_type})
    render_click(week, "toggle_rotation_filter", %{"type" => "strong_gynecology"})
    refute has_element?(week, group())
    refute has_element?(week, "#day-activities [data-resident-id='#{ctx.juniper.resident_id}']")
  end

  test "base rotations and multiple imported tasks count the same person once", ctx do
    import_task("HH Nights 2nd Call")
    import_task("HH Nights Extra")

    {:ok, _} =
      Rotations.insert_rotations(ctx.juniper.id, [
        %{
          slot_index: 1,
          start_date: ~D[2026-10-10],
          end_date: ~D[2026-10-10],
          rotation_type: :highland_weekend_nights
        }
      ])

    before = Rotations.list_rotations_for_resident(ctx.juniper.id)
    {:ok, view, _} = live(ctx.conn, "/calendar?view=week&date=#{@day}")
    assert has_element?(view, day_cell() <> " .font-mono", "1")
    open_day(view)
    assert has_element?(view, group() <> " > h3", "1 resident")
    refute has_element?(view, person(ctx.juniper), "HH Nights 2nd Call")
    refute has_element?(view, person(ctx.juniper), "HH Nights Extra")

    source_tasks =
      DetailedSchedules.list_for_resident(ctx.juniper.id, ~D[2026-10-10])
      |> Enum.map(& &1.raw_task)

    assert "HH Nights 2nd Call" in source_tasks
    assert "HH Nights Extra" in source_tasks

    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query(person(ctx.juniper))
           |> Enum.count() == 1

    assert Rotations.list_rotations_for_resident(ctx.juniper.id) == before
  end

  test "weekday nights and unrecognized Saturday labels retain literal uncategorized behavior",
       ctx do
    import_task("HH Nights 3rd Call")
    {:ok, weekday, _} = live(ctx.conn, "/calendar?view=day&date=2026-10-05")
    refute has_element?(weekday, group())

    assert has_element?(
             weekday,
             "#day-activities [data-resident-id='#{ctx.iris.resident_id}']",
             "HH Nights 3rd Call"
           )

    import_task("HH Nights Unreviewed")
    {:ok, saturday, _} = live(ctx.conn, "/calendar?view=day&date=#{@day}")

    assert has_element?(
             saturday,
             "#day-activities [data-resident-id='#{ctx.juniper.resident_id}']",
             "HH Nights Unreviewed"
           )

    refute has_element?(saturday, person(ctx.juniper), "HH Nights Unreviewed")
  end

  test "calendar summaries preserve base coverage counts and the coverer's original service",
       ctx do
    for {resident, type} <- [{ctx.iris, :highland_weekend_nights}, {ctx.juniper, :oncology}] do
      {:ok, _} =
        Rotations.insert_rotations(resident.id, [
          %{
            slot_index: 1,
            start_date: ~D[2026-10-10],
            end_date: ~D[2026-10-10],
            rotation_type: type
          }
        ])
    end

    rotation =
      Enum.find(
        Rotations.list_rotations_for_resident(ctx.iris.id),
        &(&1.start_date == ~D[2026-10-10])
      )

    {:ok, _} =
      ShiftOverrides.create_override(%{
        rotation_id: rotation.id,
        covering_schedule_resident_id: ctx.juniper.id,
        override_start_date: ~D[2026-10-10],
        override_end_date: ~D[2026-10-10]
      })

    {:ok, week, _} = live(ctx.conn, "/calendar?view=week&date=#{@day}")
    assert has_element?(week, day_cell() <> " div", ~r/Weekend Nights – Highland\s+1/)
    assert has_element?(week, day_cell() <> " div", ~r/Oncology\s+1/)
    refute has_element?(week, day_cell() <> " div", ~r/Weekend Nights – Highland\s+2/)

    {:ok, month, _} = live(ctx.conn, "/calendar?view=month&date=#{@day}")
    assert has_element?(month, day_cell() <> " span[title='#{@label}']")
    assert has_element?(month, day_cell() <> " span[title='Oncology']")
  end

  test "unclassified tasks are excluded with their base rotation until filters are cleared",
       ctx do
    import_task("HH Nights 3rd Call")

    {:ok, _} =
      Rotations.insert_rotations(ctx.iris.id, [
        %{
          slot_index: 1,
          start_date: ~D[2026-10-05],
          end_date: ~D[2026-10-05],
          rotation_type: :oncology
        }
      ])

    {:ok, view, _} = live(ctx.conn, "/calendar?view=day&date=2026-10-05")
    render_click(view, "toggle_rotation_filter", %{"type" => @night_type})
    refute has_element?(view, "#day-activities [data-rotation-type='oncology']")

    refute has_element?(
             view,
             "#day-activities [data-resident-id='#{ctx.iris.resident_id}']",
             "HH Nights 3rd Call"
           )

    refute has_element?(view, "#day-activities h3", "Daily assignments")
    render_click(view, "clear_rotation_filter", %{})

    assert has_element?(
             view,
             "#day-activities [data-rotation-type='oncology']",
             "HH Nights 3rd Call"
           )
  end

  test "a matching Saturday Night Float base does not gain a duplicate Weekend Nights category",
       ctx do
    import_task("HH Nights 3rd Call")

    {:ok, _} =
      Rotations.insert_rotations(ctx.juniper.id, [
        %{
          slot_index: 1,
          start_date: ~D[2026-10-10],
          end_date: ~D[2026-10-10],
          rotation_type: :highland_night_float
        }
      ])

    for mode <- ["month", "week"] do
      {:ok, view, _} = live(ctx.conn, "/calendar?view=#{mode}&date=#{@day}")

      if mode == "month" do
        assert has_element?(view, day_cell() <> " span[title='Night Float – Highland']")
        refute has_element?(view, day_cell() <> " span[title='#{@label}']")
      else
        assert has_element?(view, day_cell(), "Night Float – Highland")
        refute has_element?(view, day_cell(), @label)
      end

      open_day(view)

      row =
        "#day-activities [data-rotation-type='highland_night_float'] [data-resident-id='#{ctx.juniper.resident_id}']"

      assert has_element?(view, row <> " a[href='/residents/#{ctx.juniper.id}']")
      refute has_element?(view, row <> " [data-role='daily-tasks']", "HH Nights 3rd Call")
      refute has_element?(view, group())
      render_click(view, "toggle_filter_panel", %{"panel" => "rotations"})
      assert has_element?(view, "button[phx-value-type='highland_night_float']")
      refute has_element?(view, "button[phx-value-type='highland_weekend_nights']")
      render_click(view, "toggle_rotation_filter", %{"type" => "highland_weekend_nights"})
      refute has_element?(view, group())
      refute has_element?(view, "#day-activities", "HH Nights 3rd Call")
    end
  end

  defp group, do: "#day-activities [data-rotation-type='#{@night_type}']"
  defp person(resident), do: group() <> " [data-resident-id='#{resident.resident_id}']"
  defp day_cell, do: "[phx-click='select_day'][phx-value-date='#{@day}']"
  defp open_day(view), do: view |> element(day_cell()) |> render_click()

  defp import_task(task) do
    binary =
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
            {"GOG Continuity Clinic AM", task}
          ],
          xml,
          fn {old, new}, content -> String.replace(content, old, new) end
        )
      end)

    {:ok, preview} = detail_preview(binary)
    {:ok, _} = DetailedSchedules.commit(preview, ResidencySchedule.ScheduleFixtures.admin_user())
  end
end
