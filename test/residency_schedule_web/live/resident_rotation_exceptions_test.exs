defmodule ResidencyScheduleWeb.ResidentRotationExceptionsTest do
  use ResidencyScheduleWeb.ConnCase

  import Phoenix.LiveViewTest

  alias ResidencySchedule.DetailedSchedules.{Activity, ActivitySource, ImportBatch}
  alias ResidencySchedule.{Repo, Residents, Rotations, Schedules}

  @baseline "SMH Gynecology Chief On Call Day"

  setup :authenticate_session

  setup do
    {:ok, schedule} = Schedules.upsert_schedule(2026, "2026–2027")

    {:ok, resident} =
      Residents.insert_resident(schedule.id, %{
        name: "Iris Reed",
        position_code: "R4-1",
        residency_year: 4,
        schedule_number: 1
      })

    {:ok, _} =
      Rotations.insert_rotations(resident.id, [
        %{
          slot_index: 0,
          start_date: ~D[2026-10-12],
          end_date: ~D[2026-10-16],
          rotation_type: :strong_gynecology
        }
      ])

    batch =
      Repo.insert!(%ImportBatch{
        schedule_id: schedule.id,
        created_by_id: ResidencySchedule.ScheduleFixtures.admin_user().id,
        fingerprint: Ecto.UUID.generate(),
        header_start: ~D[2026-10-12],
        header_end: ~D[2026-10-16]
      })

    %{resident: resident, batch: batch}
  end

  test "modal hides repeated rotation assignments and empty days but preserves clinic exceptions",
       ctx do
    for date <- Date.range(~D[2026-10-12], ~D[2026-10-16]) do
      add_activity(ctx, date, @baseline)
    end

    add_activity(ctx, ~D[2026-10-13], "COB Continuity Clinic AM", ["Clinic starts at 8:30"])
    add_activity(ctx, ~D[2026-10-13], "COB Continuity Clinic PM")
    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.resident.id}")
    open_first_rotation(view)

    assert has_element?(view, "#shift-coworkers-modal-title", "Gynecology – Strong Memorial")
    assert has_element?(view, day("2026-10-13"), "COB Continuity Clinic AM")
    assert has_element?(view, day("2026-10-13"), "COB Continuity Clinic PM")
    assert has_element?(view, day("2026-10-13"), "Clinic starts at 8:30")
    refute has_element?(view, "#rotation-daily-assignments", @baseline)

    for date <- ["2026-10-12", "2026-10-14", "2026-10-15", "2026-10-16"] do
      refute has_element?(view, day(date))
    end

    assert has_element?(view, "#shift-coworkers-list", "Iris Reed")
  end

  test "modal retains meaningful baseline notes and tasks that differ from the selected rotation",
       ctx do
    for date <- Date.range(~D[2026-10-12], ~D[2026-10-16]) do
      notes =
        case date do
          ~D[2026-10-13] -> ["Continuity clinic", "<b>literal note</b>"]
          ~D[2026-10-16] -> [" ", "\t\n"]
          _ -> []
        end

      add_activity(ctx, date, @baseline, notes)
    end

    add_activity(ctx, ~D[2026-10-14], "HH GYN R4")
    add_activity(ctx, ~D[2026-10-15], "Unreviewed Gynecology Assignment")
    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.resident.id}")
    open_first_rotation(view)

    refute has_element?(view, day("2026-10-12"))
    assert has_element?(view, day("2026-10-13"), @baseline)
    assert has_element?(view, day("2026-10-13"), "Continuity clinic")
    assert has_element?(view, day("2026-10-13"), "<b>literal note</b>")
    refute has_element?(view, day("2026-10-13") <> " b", "literal note")
    assert has_element?(view, day("2026-10-14"), "HH GYN R4")
    assert has_element?(view, day("2026-10-15"), "Unreviewed Gynecology Assignment")
    refute has_element?(view, day("2026-10-16"))
  end

  for baseline? <- [true, false] do
    test "modal omits daily assignments entirely when baseline tasks present is #{baseline?}",
         ctx do
      if unquote(baseline?) do
        for date <- Date.range(~D[2026-10-12], ~D[2026-10-16]) do
          add_activity(ctx, date, @baseline)
        end
      end

      {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.resident.id}")
      open_first_rotation(view)

      assert has_element?(view, "#shift-coworkers-modal")
      assert has_element?(view, "#shift-coworkers-list", "Iris Reed")
      refute has_element?(view, "#rotation-daily-assignments")
      refute has_element?(view, "#shift-coworkers-modal", "No daily assignments recorded")
    end
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

  defp open_first_rotation(view) do
    selector =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#rotation-table tr[data-rotation-type='strong_gynecology']")
      |> LazyHTML.attribute("id")
      |> hd()

    view |> element("##{selector}") |> render_click()
  end

  defp day(date), do: "#rotation-daily-assignments [data-date='#{date}']"
end
