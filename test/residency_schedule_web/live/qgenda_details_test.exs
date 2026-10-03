defmodule ResidencyScheduleWeb.QgendaDetailsTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest
  import ResidencySchedule.QgendaDetailFixtures
  alias ResidencySchedule.DetailedSchedules

  setup do
    seed_detail_roster()
  end

  describe "confirmed save" do
    setup :admin_authenticate_session

    test "only explicit confirmation saves server-held preview; client fields cannot replace it",
         ctx do
      {:ok, view, _} = live(ctx.conn, "/admin/upload")
      upload_preview(view)
      assert DetailedSchedules.list_for_date(ctx.schedule.id, ~D[2026-12-29]) == []
      assert has_element?(view, "#qgenda-save-preview")
      render_click(view, "qgenda-save", %{"assignments" => [], "schedule_id" => "999999"})
      assert has_element?(view, "#qgenda-save-result")
      assert DetailedSchedules.list_for_date(ctx.schedule.id, ~D[2026-12-29]) |> length() == 2
      before = DetailedSchedules.list_for_date(ctx.schedule.id, ~D[2026-12-29])
      render_click(view, "qgenda-save", %{})
      assert DetailedSchedules.list_for_date(ctx.schedule.id, ~D[2026-12-29]) == before
    end

    test "forged save without preview is harmless", ctx do
      {:ok, view, _} = live(ctx.conn, "/admin/upload")
      render_click(view, "qgenda-save", %{})
      assert has_element?(view, "#qgenda-error")
      assert DetailedSchedules.list_for_date(ctx.schedule.id, ~D[2026-12-29]) == []
    end

    test "a failed replacement preview invalidates the previous save candidate", ctx do
      {:ok, view, _} = live(ctx.conn, "/admin/upload")
      upload_preview(view)
      upload_preview(view, "not an xlsx")
      render_click(view, "qgenda-save", %{})
      assert has_element?(view, "#qgenda-error")
      assert DetailedSchedules.list_for_date(ctx.schedule.id, ~D[2026-12-29]) == []
    end

    test "revoked admin cannot save an already opened preview", ctx do
      {:ok, view, _} = live(ctx.conn, "/admin/upload")
      upload_preview(view)
      create_admin()
      {:ok, _} = ResidencySchedule.Accounts.set_role(ctx.user, :resident)
      render_click(view, "qgenda-save", %{})
      assert DetailedSchedules.list_for_date(ctx.schedule.id, ~D[2026-12-29]) == []
    end
  end

  describe "daily details" do
    setup :authenticate_session

    setup do
      {:ok, preview} = detail_preview()

      {:ok, _} =
        DetailedSchedules.commit(preview, ResidencySchedule.ScheduleFixtures.admin_user())

      :ok
    end

    test "calendar shows base GYN plus PM clinic and notes", ctx do
      {:ok, view, _} = live(ctx.conn, "/calendar?view=day&date=2026-12-29")

      assert has_element?(
               view,
               "#day-activities [data-resident-id='#{ctx.iris.resident_id}']",
               "GOG Continuity Clinic PM"
             )

      assert has_element?(view, "#day-activities", "Bring simulation kit")
      assert has_element?(view, "a[href='/residents/#{ctx.iris.id}']", "Iris Reed")
      assert render(view) =~ "Gynecology"
    end

    test "calendar includes a resident with tasks but no base rotation", ctx do
      {:ok, view, _} = live(ctx.conn, "/calendar?view=day&date=2026-12-30")

      assert has_element?(
               view,
               "#day-activities [data-resident-id='#{ctx.juniper.resident_id}']",
               "Sick Backup"
             )

      assert has_element?(view, "#day-activities", "Juniper Vale")
    end

    test "resident date detail exposes tasks and preserves unknown detail wording", ctx do
      {:ok, view, _} = live(ctx.conn, "/residents/#{ctx.iris.id}")
      view |> form("#resident-activity-date-form", %{"date" => "2026-12-29"}) |> render_change()
      assert has_element?(view, "#resident-day-activities", "GOG Continuity Clinic PM")
      assert has_element?(view, "#resident-day-activities", "Bring simulation kit")
      assert has_element?(view, "#resident-day-activities", "Page 1")
      view |> form("#resident-activity-date-form", %{"date" => "2027-01-04"}) |> render_change()
      assert has_element?(view, "#resident-day-activities", "No QGenda detail")
      refute has_element?(view, "#resident-day-activities", "Off")
      refute has_element?(view, "#resident-day-activities", "Available")
    end

    test "calendar resident filters also filter detailed activities", ctx do
      {:ok, view, _} = live(ctx.conn, "/calendar?view=day&date=2026-12-30")
      render_click(view, "toggle_resident_filter", %{"id" => to_string(ctx.iris.resident_id)})
      refute has_element?(view, "#day-activities [data-resident-id='#{ctx.juniper.resident_id}']")
    end
  end

  defp upload_preview(view, binary \\ detail_workbook()) do
    view |> form("#qgenda-upload-form", %{"academic_year" => "2026"}) |> render_change()

    file =
      file_input(view, "#qgenda-upload-form", :qgenda_xlsx, [
        %{
          name: "detail.xlsx",
          content: binary,
          type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        }
      ])

    render_upload(file, "detail.xlsx")
    view |> form("#qgenda-upload-form", %{"academic_year" => "2026"}) |> render_submit()
  end
end
