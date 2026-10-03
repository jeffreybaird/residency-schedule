defmodule ResidencyScheduleWeb.QgendaProtectedDeletionTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest
  import ResidencySchedule.QgendaDetailFixtures
  alias ResidencySchedule.{DetailedSchedules, Repo, Schedules}

  setup %{conn: conn} do
    data = seed_detail_roster()
    admin = create_admin("synthetic-admin-password")
    {:ok, preview} = detail_preview()
    {:ok, _} = DetailedSchedules.commit(preview, admin)
    conn = Plug.Test.init_test_session(conn, user_id: admin.id)
    Map.merge(data, %{conn: conn})
  end

  test "context blocks deleting a year containing QGenda detail without raising", ctx do
    before = snapshot()
    assert {:error, message} = Schedules.delete_schedule(ctx.schedule.id)
    assert is_binary(message)
    assert message =~ "QGenda"
    assert snapshot() == before
  end

  test "admin delete shows an actionable error and preserves the schedule", ctx do
    before = snapshot()
    {:ok, view, _} = live(ctx.conn, "/admin")

    view
    |> element("button[phx-click='request_delete'][phx-value-id='#{ctx.schedule.id}']")
    |> render_click()

    view |> element("button[phx-click='confirm_delete']") |> render_click()
    assert has_element?(view, "#schedule-delete-error", "QGenda")
    assert has_element?(view, "#schedule-delete-error", "cannot")
    assert snapshot() == before
    assert Schedules.get_by_year(2026)
  end

  test "schedule delete shows an actionable error after valid password confirmation", ctx do
    before = snapshot()
    {:ok, view, _} = live(ctx.conn, "/schedule")
    view |> element("button[phx-click='request_delete']") |> render_click()

    view
    |> form("form[phx-submit='delete_schedule']", %{"password" => "synthetic-admin-password"})
    |> render_submit()

    assert has_element?(view, "#schedule-delete-error", "QGenda")
    assert has_element?(view, "#schedule-delete-error", "cannot")
    assert snapshot() == before
    assert DetailedSchedules.list_for_resident(ctx.iris.id, ~D[2026-12-29]) |> length() == 2
  end

  defp snapshot do
    tables = [
      "schedules",
      "schedule_residents",
      "residents",
      "rotations",
      "detailed_import_batches",
      "detailed_activities",
      "detailed_activity_sources"
    ]

    Map.new(tables, &{&1, Repo.aggregate(&1, :count, :id)})
  end
end
