defmodule ResidencyScheduleWeb.CalendarClinicLabelsTest do
  use ResidencyScheduleWeb.ConnCase

  import Phoenix.LiveViewTest
  import ResidencySchedule.QgendaDetailFixtures

  alias ResidencySchedule.{DetailedSchedules, Repo}
  alias ResidencySchedule.DetailedSchedules.{Activity, ActivitySource, ImportBatch}

  setup :authenticate_session

  setup do
    data = seed_detail_roster()
    admin = ResidencySchedule.ScheduleFixtures.admin_user()

    batch =
      Repo.insert!(%ImportBatch{
        schedule_id: data.schedule.id,
        created_by_id: admin.id,
        fingerprint: Ecto.UUID.generate(),
        header_start: ~D[2026-12-28],
        header_end: ~D[2027-01-03]
      })

    Map.put(data, :batch, batch)
  end

  for clinic <- ["COB Continuity", "GOG Continuity", "Lattimore MFM"] do
    test "#{clinic} AM and PM combine in day, month, and week details without changing source",
         ctx do
      clinic = unquote(clinic)
      add_activity(ctx, ctx.iris, ~D[2026-12-29], clinic <> " Clinic AM")
      add_activity(ctx, ctx.iris, ~D[2026-12-29], clinic <> " Clinic PM")
      before = DetailedSchedules.list_for_resident(ctx.iris.id, ~D[2026-12-29])

      for mode <- ["day", "month", "week"] do
        view = open_detail(ctx.conn, mode, "2026-12-29")
        assert has_element?(view, tasks(ctx.iris), "(#{clinic})")
        refute has_element?(view, tasks(ctx.iris), "Clinic AM")
        refute has_element?(view, tasks(ctx.iris), "Clinic PM")
      end

      assert DetailedSchedules.list_for_resident(ctx.iris.id, ~D[2026-12-29]) == before
      {:ok, resident, _} = live(ctx.conn, "/residents/#{ctx.iris.id}")
      assert has_element?(resident, "#rotation-table", clinic <> " Clinic AM")
      assert has_element?(resident, "#rotation-table", clinic <> " Clinic PM")
    end
  end

  test "pairs retain first-appearance ordering among other tasks and other clinic pairs", ctx do
    for task <- [
          "COB Continuity Clinic PM",
          "Research",
          "GOG Continuity Clinic AM",
          "COB Continuity Clinic AM",
          "GOG Continuity Clinic PM"
        ] do
      add_activity(ctx, ctx.iris, ~D[2026-12-29], task)
    end

    view = open_detail(ctx.conn, "day", "2026-12-29")
    assert has_element?(view, tasks(ctx.iris), "(COB Continuity; Research; GOG Continuity)")
  end

  test "lone periods, differing clinics, qualifiers, other people, and other dates never pair",
       ctx do
    for task <- [
          "COB Continuity Clinic AM",
          "GOG Continuity Clinic PM",
          "COB Continuity Clinic PM Extra"
        ] do
      add_activity(ctx, ctx.iris, ~D[2026-12-29], task)
    end

    add_activity(ctx, ctx.juniper, ~D[2026-12-29], "COB Continuity Clinic PM")
    add_activity(ctx, ctx.iris, ~D[2026-12-30], "COB Continuity Clinic PM")
    view = open_detail(ctx.conn, "day", "2026-12-29")

    assert has_element?(
             view,
             tasks(ctx.iris),
             "(COB Continuity Clinic AM; GOG Continuity Clinic PM; COB Continuity Clinic PM Extra)"
           )

    assert has_element?(view, tasks(ctx.juniper), "(COB Continuity Clinic PM)")
    next_day = open_detail(ctx.conn, "day", "2026-12-30")
    assert has_element?(next_day, tasks(ctx.iris), "(COB Continuity Clinic PM)")
  end

  test "only redundant continuity notes are hidden and meaningful notes remain escaped", ctx do
    notes = ["  CoNtInUiTy ClInIc  ", "continuity clinic: bring forms", "<b>Bring supplies</b>"]
    add_activity(ctx, ctx.iris, ~D[2026-12-29], "COB Continuity Clinic AM", notes)
    add_activity(ctx, ctx.iris, ~D[2026-12-29], "COB Continuity Clinic PM")
    add_activity(ctx, ctx.juniper, ~D[2026-12-29], "Research", ["continuity clinic"])

    add_activity(ctx, ctx.stone, ~D[2026-12-29], "GOG Continuity Clinic PM", ["continuity clinic"])

    before = DetailedSchedules.list_for_resident(ctx.iris.id, ~D[2026-12-29])

    for mode <- ["day", "month", "week"] do
      view = open_detail(ctx.conn, mode, "2026-12-29")
      refute has_element?(view, row(ctx.iris) <> " p", ~r/^\s*continuity clinic\s*$/i)
      assert has_element?(view, row(ctx.iris) <> " p", "continuity clinic: bring forms")
      assert has_element?(view, row(ctx.iris) <> " p", "<b>Bring supplies</b>")
      refute has_element?(view, row(ctx.iris) <> " p b")
      assert has_element?(view, row(ctx.juniper) <> " p", "continuity clinic")
      assert has_element?(view, tasks(ctx.stone), "(GOG Continuity Clinic PM)")
      refute has_element?(view, row(ctx.stone) <> " p", ~r/^continuity clinic$/i)
    end

    assert DetailedSchedules.list_for_resident(ctx.iris.id, ~D[2026-12-29]) == before
    {:ok, resident, _} = live(ctx.conn, "/residents/#{ctx.iris.id}")
    assert has_element?(resident, "#rotation-table", "CoNtInUiTy ClInIc")
  end

  defp row(resident), do: "#day-activities [data-resident-id='#{resident.resident_id}']"
  defp tasks(resident), do: row(resident) <> " [data-role='daily-tasks']"

  defp open_detail(conn, mode, date) do
    {:ok, view, _} = live(conn, "/calendar?view=#{mode}&date=#{date}")

    if mode != "day",
      do:
        view |> element("[data-action='select_day'][phx-value-date='#{date}']") |> render_click()

    view
  end

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
  end
end
