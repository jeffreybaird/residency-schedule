defmodule ResidencyScheduleWeb.VacationAdjacentRotationsTest do
  use ResidencyScheduleWeb.ConnCase

  import Phoenix.LiveViewTest

  alias ResidencySchedule.DetailedSchedules.{Activity, ActivitySource, ImportBatch}
  alias ResidencySchedule.{Repo, Residents, Rotations, Schedules}

  setup :authenticate_session

  setup do
    {:ok, schedule} = Schedules.upsert_schedule(2026, "2026–2027")
    resident = add_resident(schedule, "Iris Reed", 1)

    batch =
      Repo.insert!(%ImportBatch{
        schedule_id: schedule.id,
        created_by_id: ResidencySchedule.ScheduleFixtures.admin_user().id,
        fingerprint: Ecto.UUID.generate(),
        header_start: ~D[2027-04-05],
        header_end: ~D[2027-04-18]
      })

    %{resident: resident, schedule: schedule, batch: batch}
  end

  test "weekday roster and imported weekend Vacation merge into one fourteen day block", ctx do
    add_rotations(ctx.resident, :vacation, [
      {0, ~D[2027-04-05], ~D[2027-04-09]},
      {1, ~D[2027-04-12], ~D[2027-04-16]}
    ])

    for date <- [~D[2027-04-10], ~D[2027-04-11], ~D[2027-04-17], ~D[2027-04-18]] do
      add_activity(ctx, date, "Vacation", ["Vacation note #{date}"])
    end

    coworker = add_resident(ctx.schedule, "Juniper Vale", 2)
    add_rotations(coworker, :vacation, [{2, ~D[2027-04-18], ~D[2027-04-18]}])
    before = Rotations.list_rotations_for_resident(ctx.resident.id)
    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.resident.id}")
    selector = row("vacation", "2027-04-05", "2027-04-18")

    assert has_element?(view, selector <> " span[title='Vacation']", "Vacation")
    assert has_element?(view, selector <> " td:last-child", ~r/^\s*14\s*$/)
    assert count_rows(view, "#rotation-table tr[data-rotation-type='vacation']") == 1
    refute has_element?(view, "#rotation-table tr[data-entry-kind='activity']")

    for day <- [10, 11, 17, 18] do
      assert has_element?(view, selector <> " p", "Apr #{day}: Vacation note 2027-04-#{day}")
    end

    view |> element(selector) |> render_click()

    assert has_element?(view, "#shift-coworkers-modal", "Apr 5, 2027 – Apr 18, 2027")
    assert has_element?(view, "#shift-coworkers-list", "Juniper Vale")

    assert has_element?(
             view,
             "#rotation-daily-assignments [data-date='2027-04-10']",
             "Vacation note 2027-04-10"
           )

    assert has_element?(
             view,
             "#rotation-daily-assignments [data-date='2027-04-18']",
             "Vacation note 2027-04-18"
           )

    assert Rotations.list_rotations_for_resident(ctx.resident.id) == before
  end

  test "Vacation rows remain separate when a weekend has no assignment", ctx do
    add_rotations(ctx.resident, :vacation, [
      {0, ~D[2027-04-05], ~D[2027-04-09]},
      {1, ~D[2027-04-12], ~D[2027-04-16]}
    ])

    for date <- [~D[2027-04-17], ~D[2027-04-18]] do
      add_activity(ctx, date, "Vacation")
    end

    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.resident.id}")

    assert has_element?(view, row("vacation", "2027-04-05", "2027-04-09"))
    assert has_element?(view, row("vacation", "2027-04-12", "2027-04-18"))
    assert count_rows(view, "#rotation-table tr[data-rotation-type='vacation']") == 2
    refute has_element?(view, row("vacation", "2027-04-05", "2027-04-18"))
  end

  test "different visible duty labels on consecutive dates retain separate blocks", ctx do
    add_rotations(ctx.resident, :strong_gynecology, [
      {0, ~D[2027-04-05], ~D[2027-04-06]}
    ])

    add_activity(ctx, ~D[2027-04-05], "SMH GYN R2 Day")
    add_activity(ctx, ~D[2027-04-06], "SMH GYN R3 Day")

    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.resident.id}")

    assert has_element?(
             view,
             row("strong_gynecology", "2027-04-05", "2027-04-05"),
             "SMH GYN R2 Day"
           )

    assert has_element?(
             view,
             row("strong_gynecology", "2027-04-06", "2027-04-06"),
             "SMH GYN R3 Day"
           )

    assert count_rows(view, "#rotation-table tr[data-rotation-type='strong_gynecology']") == 2
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

  defp add_rotations(resident, type, spans) do
    rotations =
      Enum.map(spans, fn {slot, first, last} ->
        %{slot_index: slot, start_date: first, end_date: last, rotation_type: type}
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

  defp row(type, first, last),
    do:
      "#rotation-table tr[data-rotation-type='#{type}'][phx-value-start-date='#{first}'][phx-value-end-date='#{last}']"

  defp count_rows(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.count()
  end
end
