defmodule ResidencyScheduleWeb.ImportedResidentNamesTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest
  import ResidencySchedule.QgendaDetailFixtures
  alias ResidencySchedule.{DetailedSchedules, Residents, Rotations}

  setup :authenticate_session

  setup do
    data = seed_detail_roster()
    {:ok, preview} = detail_preview()
    {:ok, _} = DetailedSchedules.commit(preview, ResidencySchedule.ScheduleFixtures.admin_user())

    {:ok, _} =
      Rotations.insert_rotations(data.juniper.id, [
        %{
          slot_index: 0,
          start_date: ~D[2026-12-28],
          end_date: ~D[2027-01-03],
          rotation_type: :strong_gynecology
        }
      ])

    {:ok, fallback} =
      Residents.insert_resident(data.schedule.id, %{
        name: "Other, Juniper",
        position_code: "R2-4",
        residency_year: 2,
        schedule_number: 4
      })

    {:ok, _} =
      Rotations.insert_rotations(fallback.id, [
        %{
          slot_index: 0,
          start_date: ~D[2026-12-28],
          end_date: ~D[2027-01-03],
          rotation_type: :strong_gynecology
        }
      ])

    Map.put(data, :fallback, fallback)
  end

  test "resident page header uses imported full name with a normalized fallback", ctx do
    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.juniper.id}")
    assert has_element?(view, "h1", "Juniper Vale")
    refute has_element?(view, "h1", "Juniper Vail")
    {:ok, other, _} = live(ctx.conn, "/residents/#{ctx.fallback.id}")
    assert has_element?(other, "h1", "Juniper Other")
    refute has_element?(other, "h1", "Juniper Vale")
  end

  test "compare selectors use stable-person imported names and isolated fallbacks", ctx do
    {:ok, view, _} = live(ctx.conn, "/compare")
    assert has_element?(view, "option[value='#{ctx.juniper.id}']", "Juniper Vale")
    refute has_element?(view, "option[value='#{ctx.juniper.id}']", "Juniper Vail")
    assert has_element?(view, "option[value='#{ctx.fallback.id}']", "Juniper Other")
  end

  test "Gantt resident labels use the same preferred names", ctx do
    {:ok, view, _} = live(ctx.conn, "/schedule")
    assert has_element?(view, "a[href='/residents/#{ctx.juniper.id}']", "Juniper Vale")
    refute has_element?(view, "a[href='/residents/#{ctx.juniper.id}']", "Juniper Vail")
    assert has_element?(view, "a[href='/residents/#{ctx.fallback.id}']", "Juniper Other")
  end

  test "calendar day and month modal rotation names agree with activity names", ctx do
    {:ok, view, _} = live(ctx.conn, "/calendar?view=day&date=2026-12-29")

    assert has_element?(
             view,
             "#tour-calendar-grid a[href='/residents/#{ctx.juniper.id}']",
             "Juniper Vale"
           )

    refute has_element?(
             view,
             "#tour-calendar-grid a[href='/residents/#{ctx.juniper.id}']",
             "Juniper Vail"
           )

    {:ok, month, _} = live(ctx.conn, "/calendar?view=month&date=2026-12-29")
    render_click(month, "select_day", %{"date" => "2026-12-29"})
    assert has_element?(month, "a[href='/residents/#{ctx.juniper.id}']", "Juniper Vale")
    refute has_element?(month, "a[href='/residents/#{ctx.juniper.id}']", "Juniper Vail")
  end

  test "rotation coworker modal and coworkers tab show the preferred names", ctx do
    {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.iris.id}")
    view |> element("#rotation-entry-strong_gynecology-0-2026-12-28-2027-01-03") |> render_click()
    assert has_element?(view, "#shift-coworkers-list", "Juniper Vale")
    refute has_element?(view, "#shift-coworkers-list", "Juniper Vail")
    assert has_element?(view, "#shift-coworkers-list", "Juniper Other")
    render_click(view, "close_shift_coworkers", %{})
    view |> element("button[phx-value-tab='coworkers']") |> render_click()
    assert has_element?(view, "#coworker-row-#{ctx.juniper.id}", "Juniper Vale")
    assert has_element?(view, "#coworker-row-#{ctx.fallback.id}", "Juniper Other")
  end
end
