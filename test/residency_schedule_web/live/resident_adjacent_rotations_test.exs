defmodule ResidencyScheduleWeb.ResidentAdjacentRotationsTest do
  use ResidencyScheduleWeb.ConnCase

  import Phoenix.LiveViewTest

  alias ResidencySchedule.DetailedSchedules.{Activity, ActivitySource, ImportBatch}
  alias ResidencySchedule.{Repo, Residents, Rotations, Schedules, ShiftOverrides}

  setup :authenticate_session

  setup do
    {:ok, schedule} = Schedules.upsert_schedule(2026, "2026–2027")
    resident = add_resident(schedule, "Iris Reed", 1)

    batch =
      Repo.insert!(%ImportBatch{
        schedule_id: schedule.id,
        created_by_id: ResidencySchedule.ScheduleFixtures.admin_user().id,
        fingerprint: Ecto.UUID.generate(),
        header_start: ~D[2026-10-12],
        header_end: ~D[2026-10-16]
      })

    %{resident: resident, schedule: schedule, batch: batch}
  end

  test "consecutive base rotations form one inclusive span across source slots", ctx do
    add_rotations(ctx.resident, [
      {2, ~D[2026-10-15], ~D[2026-10-16]},
      {0, ~D[2026-10-12], ~D[2026-10-12]},
      {1, ~D[2026-10-13], ~D[2026-10-14]}
    ])

    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.resident.id}")
    selector = rotation_row("2026-10-12", "2026-10-16")

    assert has_element?(view, selector, "Gynecology – Strong Memorial")
    assert has_element?(view, selector <> " td:last-child", ~r/^\s*5\s*$/)
    assert rotation_count(view) == 1
    assert length(Rotations.list_rotations_for_resident(ctx.resident.id)) == 3
  end

  test "identical specific tasks merge with dated notes and the full coworker range", ctx do
    add_rotations(ctx.resident, [
      {0, ~D[2026-10-12], ~D[2026-10-12]},
      {1, ~D[2026-10-13], ~D[2026-10-13]}
    ])

    add_activity(ctx, ~D[2026-10-12], "SMH GYN R2 Day", ["First day handoff"])
    add_activity(ctx, ~D[2026-10-13], "SMH GYN R2 Day", ["Second day handoff"])
    coworker = add_resident(ctx.schedule, "Juniper Vale", 2)
    add_rotations(coworker, [{1, ~D[2026-10-13], ~D[2026-10-13]}])

    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.resident.id}")
    selector = rotation_row("2026-10-12", "2026-10-13")

    assert has_element?(
             view,
             selector <> " [data-role='specific-rotation-label']",
             "SMH GYN R2 Day"
           )

    assert has_element?(view, selector <> " p", "Oct 12: First day handoff")
    assert has_element?(view, selector <> " p", "Oct 13: Second day handoff")
    assert has_element?(view, selector <> " td:last-child", ~r/^\s*2\s*$/)
    assert rotation_count(view) == 1
    refute has_element?(view, "#rotation-table tr[data-entry-kind='activity']")

    view |> element(selector) |> render_click()

    assert has_element?(view, "#shift-coworkers-modal", "Oct 12, 2026 – Oct 13, 2026")
    assert has_element?(view, "#shift-coworkers-list", "Juniper Vale")

    assert has_element?(
             view,
             "#rotation-daily-assignments [data-date='2026-10-12']",
             "First day handoff"
           )

    assert has_element?(
             view,
             "#rotation-daily-assignments [data-date='2026-10-13']",
             "Second day handoff"
           )
  end

  test "a concurrent independent rotation does not interrupt consecutive matching rotations",
       ctx do
    add_rotations(ctx.resident, [
      {0, ~D[2026-10-12], ~D[2026-10-12]},
      {2, ~D[2026-10-13], ~D[2026-10-13]}
    ])

    {:ok, _} =
      Rotations.insert_rotations(ctx.resident.id, [
        %{
          slot_index: 1,
          start_date: ~D[2026-10-12],
          end_date: ~D[2026-10-12],
          rotation_type: :oncology
        }
      ])

    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.resident.id}")

    assert has_element?(view, rotation_row("2026-10-12", "2026-10-13"))
    assert rotation_count(view) == 1

    assert has_element?(
             view,
             "#rotation-table tr[data-rotation-type='oncology'][phx-value-start-date='2026-10-12'][phx-value-end-date='2026-10-12']"
           )
  end

  test "different imported assignment labels retain separate adjacent spans", ctx do
    add_activity(ctx, ~D[2026-10-12], "Unreviewed Service Alpha")
    add_activity(ctx, ~D[2026-10-13], "Unreviewed Service Beta")

    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.resident.id}")

    assert has_element?(
             view,
             "#rotation-table tr[data-rotation-type='qgenda_assignment'][phx-value-start-date='2026-10-12'][phx-value-end-date='2026-10-12']",
             "Unreviewed Service Alpha"
           )

    assert has_element?(
             view,
             "#rotation-table tr[data-rotation-type='qgenda_assignment'][phx-value-start-date='2026-10-13'][phx-value-end-date='2026-10-13']",
             "Unreviewed Service Beta"
           )
  end

  test "adjacent unmatched daily assignments retain their individual dates", ctx do
    add_rotations(ctx.resident, [
      {0, ~D[2026-10-12], ~D[2026-10-12]},
      {1, ~D[2026-10-13], ~D[2026-10-13]}
    ])

    for date <- [~D[2026-10-12], ~D[2026-10-13]] do
      add_activity(ctx, date, "COB Continuity Clinic AM", ["Bring clinic materials"])
    end

    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.resident.id}")

    assert has_element?(view, rotation_row("2026-10-12", "2026-10-13"))

    for date <- ["2026-10-12", "2026-10-13"] do
      selector = "#rotation-table tr[data-entry-kind='activity'][data-date='#{date}']"
      assert has_element?(view, selector, "COB Continuity Clinic AM")
      assert has_element?(view, selector, "Bring clinic materials")
      assert has_element?(view, selector <> " td:last-child", ~r/^\s*1\s*$/)
    end

    assert view
           |> render()
           |> LazyHTML.from_fragment()
           |> LazyHTML.query("#rotation-table tr[data-entry-kind='activity']")
           |> Enum.count() == 2
  end

  test "overlapping source spans are preserved rather than merged as consecutive days", ctx do
    add_rotations(ctx.resident, [
      {0, ~D[2026-10-12], ~D[2026-10-13]},
      {1, ~D[2026-10-13], ~D[2026-10-14]}
    ])

    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.resident.id}")

    assert has_element?(view, rotation_row("2026-10-12", "2026-10-13"))
    assert has_element?(view, rotation_row("2026-10-13", "2026-10-14"))
    assert rotation_count(view) == 2
    refute has_element?(view, rotation_row("2026-10-12", "2026-10-14"))
  end

  test "a calendar gap keeps identical rotations separate", ctx do
    add_rotations(ctx.resident, [
      {0, ~D[2026-10-12], ~D[2026-10-12]},
      {1, ~D[2026-10-14], ~D[2026-10-14]}
    ])

    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.resident.id}")

    assert has_element?(view, rotation_row("2026-10-12", "2026-10-12"))
    assert has_element?(view, rotation_row("2026-10-14", "2026-10-14"))
    assert rotation_count(view) == 2
    refute has_element?(view, rotation_row("2026-10-12", "2026-10-14"))
  end

  test "different specific tasks and the general label retain separate adjacent spans", ctx do
    add_rotations(ctx.resident, [{0, ~D[2026-10-12], ~D[2026-10-14]}])
    add_activity(ctx, ~D[2026-10-12], "SMH GYN R2 Day")
    add_activity(ctx, ~D[2026-10-13], "SMH GYN R3 Day")

    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.resident.id}")

    assert has_element?(view, rotation_row("2026-10-12", "2026-10-12"), "SMH GYN R2 Day")
    assert has_element?(view, rotation_row("2026-10-13", "2026-10-13"), "SMH GYN R3 Day")

    assert has_element?(
             view,
             rotation_row("2026-10-14", "2026-10-14"),
             "Gynecology – Strong Memorial"
           )

    assert rotation_count(view) == 3
  end

  test "adjacent rotations from separate academic schedules retain their schedule identity",
       ctx do
    {:ok, prior_schedule} = Schedules.upsert_schedule(2025, "2025–2026")

    {:ok, prior_resident} =
      Residents.insert_resident(prior_schedule.id, %{
        name: "Iris Reed",
        resident_id: ctx.resident.resident_id,
        position_code: "R3-1",
        residency_year: 3,
        schedule_number: 1
      })

    add_rotations(prior_resident, [{0, ~D[2026-06-30], ~D[2026-06-30]}])
    add_rotations(ctx.resident, [{0, ~D[2026-07-01], ~D[2026-07-01]}])

    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.resident.id}")

    assert has_element?(
             view,
             rotation_row("2026-06-30", "2026-06-30") <>
               "[phx-value-schedule-id='#{prior_schedule.id}']"
           )

    assert has_element?(
             view,
             rotation_row("2026-07-01", "2026-07-01") <>
               "[phx-value-schedule-id='#{ctx.schedule.id}']"
           )

    assert rotation_count(view) == 2
  end

  test "coverage changes retain separate spans even with the same rotation label", ctx do
    add_rotations(ctx.resident, [{0, ~D[2026-10-12], ~D[2026-10-14]}])
    [rotation] = Rotations.list_rotations_for_resident(ctx.resident.id)
    cover = add_resident(ctx.schedule, "Juniper Vale", 2)

    {:ok, _} =
      ShiftOverrides.create_override(%{
        rotation_id: rotation.id,
        covering_schedule_resident_id: cover.id,
        override_start_date: ~D[2026-10-13],
        override_end_date: ~D[2026-10-13]
      })

    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.resident.id}")

    assert has_element?(view, rotation_row("2026-10-12", "2026-10-12"))
    assert has_element?(view, rotation_row("2026-10-13", "2026-10-13"), "covered by Juniper Vale")
    assert has_element?(view, rotation_row("2026-10-14", "2026-10-14"))
    assert rotation_count(view) == 3
  end

  defp add_resident(schedule, name, number) do
    {:ok, resident} =
      Residents.insert_resident(schedule.id, %{
        name: name,
        position_code: "R4-#{number}",
        residency_year: 4,
        schedule_number: number
      })

    resident
  end

  defp add_rotations(resident, spans) do
    rotations =
      Enum.map(spans, fn {slot, first, last} ->
        %{slot_index: slot, start_date: first, end_date: last, rotation_type: :strong_gynecology}
      end)

    assert {:ok, _} = Rotations.insert_rotations(resident.id, rotations)
  end

  defp add_activity(ctx, date, task, notes \\ []) do
    activity =
      Repo.insert!(%Activity{schedule_resident_id: ctx.resident.id, date: date, raw_task: task})

    Repo.insert!(%ActivitySource{
      activity_id: activity.id,
      batch_id: ctx.batch.id,
      source_sheet: "Synthetic",
      source_cell: "A#{activity.id}",
      raw_staff: ctx.resident.name,
      display_name: ctx.resident.name,
      previous_name: ctx.resident.name,
      notes: Enum.map(notes, &%{"text" => &1})
    })
  end

  defp rotation_row(first, last),
    do:
      "#rotation-table tr[data-rotation-type='strong_gynecology'][phx-value-start-date='#{first}'][phx-value-end-date='#{last}']"

  defp rotation_count(view) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#rotation-table tr[data-rotation-type='strong_gynecology']")
    |> Enum.count()
  end
end
