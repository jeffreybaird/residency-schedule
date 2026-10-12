defmodule ResidencyScheduleWeb.CalendarRedundantAssignmentsTest do
  use ResidencyScheduleWeb.ConnCase

  import Phoenix.LiveViewTest
  import ResidencySchedule.QgendaDetailFixtures

  alias ResidencySchedule.{DetailedSchedules, Rotations}

  setup :authenticate_session

  setup do
    seed_detail_roster()
  end

  for {task, type} <- [
        {"Ambulatory R1", :ambulatory},
        {"Ambulatory R2", :ambulatory},
        {"Ambulatory R3", :ambulatory},
        {"Ambulatory R4", :ambulatory},
        {"Elective R3", :elective},
        {"Elective R4", :elective}
      ] do
    test "#{task} is omitted only when it repeats the #{type} heading", ctx do
      task = unquote(task)
      type = unquote(type)
      import_task(task)
      insert_rotation(ctx.iris.id, type, ~D[2026-12-29])
      {:ok, view, _} = live(ctx.conn, "/calendar?view=day&date=2026-12-29")
      row = resident_row(type, ctx.iris)

      assert has_element?(
               view,
               "#day-activities [data-rotation-type='#{type}'] > h3",
               Rotations.rotation_type_label(to_string(type))
             )

      assert has_element?(view, row <> " [data-role='daily-tasks']", "(GOG Continuity Clinic PM)")
      refute has_element?(view, row <> " [data-role='daily-tasks']", task)
      assert has_element?(view, row, "Bring simulation kit")

      # The same source task remains meaningful beneath a different rotation.
      assert has_element?(
               view,
               resident_row(:strong_gynecology, ctx.iris) <> " [data-role='daily-tasks']",
               task
             )

      assert Enum.any?(
               DetailedSchedules.list_for_resident(ctx.iris.id, ~D[2026-12-29]),
               &(&1.raw_task == task)
             )

      # With no corresponding base rotation, the task remains visible.
      {:ok, activity_only, _} = live(ctx.conn, "/calendar?view=day&date=2026-12-30")
      juniper = "#day-activities [data-resident-id='#{ctx.juniper.resident_id}']"
      assert has_element?(activity_only, juniper <> " [data-role='daily-tasks']", "(#{task})")

      insert_rotation(ctx.juniper.id, type, ~D[2026-12-30])
      {:ok, only_redundant, _} = live(ctx.conn, "/calendar?view=day&date=2026-12-30")

      assert has_element?(
               only_redundant,
               resident_row(type, ctx.juniper) <> " a[href='/residents/#{ctx.juniper.id}']"
             )

      refute has_element?(
               only_redundant,
               resident_row(type, ctx.juniper) <> " [data-role='daily-tasks']"
             )

      refute has_element?(only_redundant, resident_row(type, ctx.juniper), "()")
      assert has_element?(only_redundant, resident_row(type, ctx.juniper), "Coverage discussion")

      assert [%{raw_task: ^task}] =
               DetailedSchedules.list_for_resident(ctx.juniper.id, ~D[2026-12-30])
    end
  end

  defp resident_row(type, resident),
    do:
      "#day-activities [data-rotation-type='#{type}'] [data-resident-id='#{resident.resident_id}']"

  defp insert_rotation(resident_id, type, date) do
    {:ok, _} =
      Rotations.insert_rotations(resident_id, [
        %{slot_index: 1, start_date: date, end_date: date, rotation_type: type}
      ])
  end

  defp import_task(task) do
    binary =
      mutate_detail_workbook("xl/sharedStrings.xml", fn xml ->
        xml
        |> String.replace(
          "12/29/2026 Tue Reed, Iris SMH GYN R2 Day Coverage discussion",
          "12/30/2026 Wed Vale, Juniper Sick Backup Coverage discussion"
        )
        |> String.replace("SMH GYN R2 Day", task)
        |> String.replace("Sick Backup", task)
      end)

    {:ok, preview} = detail_preview(binary)
    {:ok, _} = DetailedSchedules.commit(preview, ResidencySchedule.ScheduleFixtures.admin_user())
  end
end
