defmodule ResidencyScheduleWeb.CalendarRotationGroupsTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest
  import ResidencySchedule.ScheduleFixtures
  import ResidencySchedule.QgendaDetailFixtures

  alias ResidencySchedule.{DetailedSchedules, Rotations, ShiftOverrides}

  setup :authenticate_session

  describe "rotation groups without QGenda assignments" do
    setup do
      seed_mini_schedule()
    end

    test "month and week modals group residents under each rotation instead of resident order",
         ctx do
      for mode <- ["month", "week"] do
        {:ok, view, _} = live(ctx.conn, "/calendar?view=#{mode}&date=2026-07-06")
        open_day(view, "2026-07-06")

        assert_grouped_roster(view, ctx)
        assert has_element?(view, "button[phx-click='open_day_view']")
      end
    end

    test "opening the full day view preserves the modal's rotation groups", ctx do
      {:ok, view, _} = live(ctx.conn, "/calendar?view=week&date=2026-07-06")
      open_day(view, "2026-07-06")
      view |> element("button[phx-click='open_day_view']") |> render_click()

      assert_grouped_roster(view, ctx)
      refute has_element?(view, "button[phx-click='open_day_view']")
    end

    test "filters remove excluded residents and rotation groups from the modal", ctx do
      {:ok, view, _} = live(ctx.conn, "/calendar?view=week&date=2026-07-06")
      open_day(view, "2026-07-06")
      render_click(view, "toggle_rotation_filter", %{"type" => "strong_obstetrics"})

      assert has_element?(view, group(:strong_obstetrics), "2 residents")
      refute has_element?(view, group(:oncology))

      render_click(view, "toggle_resident_filter", %{"id" => to_string(ctx.clare.resident_id)})

      assert has_element?(view, group(:strong_obstetrics), "1 resident")

      assert has_element?(
               view,
               group(:strong_obstetrics) <> " a[href='/residents/#{ctx.clare.id}']"
             )

      refute has_element?(view, "#day-activities a[href='/residents/#{ctx.mary.id}']")
      refute has_element?(view, group(:oncology))
    end

    test "coverage stays attached to the covered rotation group", ctx do
      rotation = rotation_on(ctx.tiff, ~D[2026-07-06])

      {:ok, _} =
        ShiftOverrides.create_override(%{
          rotation_id: rotation.id,
          covering_schedule_resident_id: ctx.clare.id,
          override_start_date: ~D[2026-07-06],
          override_end_date: ~D[2026-07-06]
        })

      {:ok, view, _} = live(ctx.conn, "/calendar?view=week&date=2026-07-06")
      open_day(view, "2026-07-06")

      assert has_element?(view, group(:oncology) <> " a[href='/residents/#{ctx.tiff.id}']")
      assert has_element?(view, group(:oncology) <> " a[href='/residents/#{ctx.clare.id}']")
      assert has_element?(view, group(:oncology), "Covered by Clare")
      assert has_element?(view, group(:oncology), "(covering)")
      assert has_element?(view, group(:oncology) <> " .line-through")

      refute has_element?(
               view,
               group(:strong_obstetrics) <> " a[href='/residents/#{ctx.clare.id}']"
             )

      assert has_element?(
               view,
               group(:strong_obstetrics) <> " a[href='/residents/#{ctx.mary.id}']"
             )

      assert has_element?(view, group(:strong_obstetrics), "1 resident")
      refute has_element?(view, group(:strong_obstetrics), "(covering)")
    end
  end

  describe "rotation groups with QGenda assignments" do
    setup do
      data = seed_detail_roster()
      {:ok, preview} = detail_preview()
      {:ok, _} = DetailedSchedules.commit(preview, admin_user())
      data
    end

    test "residents sharing a rotation retain their own daily tasks and notes", ctx do
      {:ok, _} =
        Rotations.insert_rotations(ctx.stone.id, [
          %{
            slot_index: 0,
            start_date: ~D[2026-12-28],
            end_date: ~D[2027-01-03],
            rotation_type: :strong_gynecology
          }
        ])

      {:ok, view, _} = live(ctx.conn, "/calendar?view=month&date=2026-12-29")
      open_day(view, "2026-12-29")
      iris_row = group(:strong_gynecology) <> " [data-resident-id='#{ctx.iris.resident_id}']"
      stone_row = group(:strong_gynecology) <> " [data-resident-id='#{ctx.stone.resident_id}']"

      assert group_types(view) == ["strong_gynecology"]
      assert has_element?(view, group(:strong_gynecology), "Gynecology")
      assert has_element?(view, group(:strong_gynecology), "2 residents")
      assert has_element?(view, iris_row <> " a[href='/residents/#{ctx.iris.id}']", "Iris Reed")
      assert has_element?(view, iris_row, "GOG Continuity Clinic PM")
      assert has_element?(view, iris_row, "Bring simulation kit")
      assert has_element?(view, stone_row <> " a[href='/residents/#{ctx.stone.id}']")
      refute has_element?(view, stone_row, "GOG Continuity Clinic PM")
      refute has_element?(view, stone_row, "Bring simulation kit")
    end

    test "concurrent rotations have one resident row per type and distinct task containers",
         ctx do
      {:ok, 2} =
        Rotations.insert_rotations(ctx.iris.id, [
          %{
            slot_index: 1,
            start_date: ~D[2026-12-29],
            end_date: ~D[2026-12-29],
            rotation_type: :strong_gynecology
          },
          %{
            slot_index: 2,
            start_date: ~D[2026-12-29],
            end_date: ~D[2026-12-29],
            rotation_type: :oncology
          }
        ])

      {:ok, view, _} = live(ctx.conn, "/calendar?view=week&date=2026-12-29")
      open_day(view, "2026-12-29")
      document = view |> render() |> LazyHTML.from_fragment()

      assert group_types(view) == ["oncology", "strong_gynecology"]

      for {type, label, other_label} <- [
            {:oncology, "Oncology", "Gynecology"},
            {:strong_gynecology, "Gynecology", "Oncology"}
          ] do
        resident_row = group(type) <> " [data-resident-id='#{ctx.iris.resident_id}']"

        assert document |> LazyHTML.query(resident_row) |> Enum.count() == 1
        assert has_element?(view, group(type) <> " > h3", "1 resident")
        assert has_element?(view, resident_row <> " a[href='/residents/#{ctx.iris.id}']")
        assert has_element?(view, resident_row, label)
        refute has_element?(view, resident_row, other_label)
        assert has_element?(view, resident_row, "GOG Continuity Clinic PM")
        assert has_element?(view, resident_row, "Bring simulation kit")
      end

      task_ids =
        document
        |> LazyHTML.query(
          "#day-activities [data-resident-id='#{ctx.iris.resident_id}'] [id^='day-tasks-']"
        )
        |> LazyHTML.attribute("id")

      assert length(task_ids) == 2
      assert length(Enum.uniq(task_ids)) == 2
    end

    test "activity-only residents remain visible outside the base rotation groups", ctx do
      {:ok, view, _} = live(ctx.conn, "/calendar?view=week&date=2026-12-30")
      open_day(view, "2026-12-30")
      juniper_row = "#day-activities [data-resident-id='#{ctx.juniper.resident_id}']"

      assert has_element?(view, group(:strong_gynecology))
      assert has_element?(view, juniper_row, "Sick Backup")
      assert has_element?(view, juniper_row <> " a[href='/residents/#{ctx.juniper.id}']")

      refute has_element?(
               view,
               group(:strong_gynecology) <> " [data-resident-id='#{ctx.juniper.resident_id}']"
             )

      render_click(view, "toggle_resident_filter", %{"id" => to_string(ctx.iris.resident_id)})
      refute has_element?(view, juniper_row)
      assert has_element?(view, group(:strong_gynecology))
    end
  end

  defp open_day(view, date) do
    view |> element("[phx-click='select_day'][phx-value-date='#{date}']") |> render_click()
  end

  defp group(type), do: "#day-activities [data-rotation-type='#{type}']"

  defp group_types(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#day-activities [data-rotation-type]")
    |> LazyHTML.attribute("data-rotation-type")
  end

  defp assert_grouped_roster(view, ctx) do
    assert group_types(view) == ["oncology", "strong_obstetrics"]
    assert has_element?(view, group(:oncology), "Oncology")
    assert has_element?(view, group(:oncology), "1 resident")
    assert has_element?(view, group(:oncology) <> " a[href='/residents/#{ctx.tiff.id}']", "Tiff")
    assert has_element?(view, group(:strong_obstetrics), "2 residents")

    assert has_element?(
             view,
             group(:strong_obstetrics) <> " a[href='/residents/#{ctx.clare.id}']",
             "Clare"
           )

    assert has_element?(
             view,
             group(:strong_obstetrics) <> " a[href='/residents/#{ctx.mary.id}']",
             "Mary"
           )

    refute has_element?(view, group(:oncology) <> " a[href='/residents/#{ctx.clare.id}']")
    refute has_element?(view, group(:strong_obstetrics) <> " a[href='/residents/#{ctx.tiff.id}']")
  end
end
