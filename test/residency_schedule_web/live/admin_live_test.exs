defmodule ResidencyScheduleWeb.AdminLiveTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest

  alias ResidencySchedule.{Schedules, Residents, Rotations}

  describe "unauthenticated access" do
    test "redirects to /admin/login when no admin session", %{conn: conn} do
      conn = get(conn, "/admin")
      assert redirected_to(conn) == "/admin/login"
    end
  end

  describe "admin page without schedules" do
    setup %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, authenticated: true, admin: true)
      {:ok, view, html} = live(conn, "/admin")
      %{conn: conn, view: view, html: html}
    end

    test "renders Admin heading", %{html: html} do
      assert html =~ "Admin"
    end

    test "renders Upload CSV link", %{html: html} do
      assert html =~ "Upload CSV"
    end

    test "renders link to /admin/upload", %{html: html} do
      assert html =~ "/admin/upload"
    end

    test "does not show delete section when no schedules", %{html: html} do
      refute html =~ "Delete a Schedule"
    end
  end

  describe "admin page with schedules" do
    setup %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, authenticated: true, admin: true)
      seed_schedule()
      {:ok, view, html} = live(conn, "/admin")
      %{conn: conn, view: view, html: html}
    end

    test "shows schedule count", %{html: html} do
      assert html =~ "1 schedule"
    end

    test "shows schedule label", %{html: html} do
      assert html =~ "2023"
    end

    test "shows Delete button for each schedule", %{html: html} do
      assert html =~ "Delete"
    end

    test "request_delete shows confirmation UI", %{view: view} do
      schedule = List.first(ResidencySchedule.Schedules.list_schedules())
      html = view |> element("button[phx-value-id='#{schedule.id}']") |> render_click()
      assert html =~ "Confirm"
      assert html =~ "Cancel"
    end

    test "cancel_delete hides confirmation UI", %{view: view} do
      schedule = List.first(ResidencySchedule.Schedules.list_schedules())
      view |> element("button[phx-value-id='#{schedule.id}']") |> render_click()
      view |> element("button[phx-click='cancel_delete']") |> render_click()
      refute has_element?(view, "button[phx-click='confirm_delete']")
    end

    test "confirm_delete removes the schedule", %{view: view} do
      schedule = List.first(ResidencySchedule.Schedules.list_schedules())
      view |> element("button[phx-value-id='#{schedule.id}']") |> render_click()
      html = view |> element("button[phx-click='confirm_delete']") |> render_click()
      refute html =~ "Delete a Schedule"
    end
  end

  describe "override form — covering residents scoped to rotation's schedule" do
    setup %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, authenticated: true, admin: true)

      # Two schedules with a resident named "Emily K" in each — same person, different years
      {:ok, sched_a} = Schedules.upsert_schedule(2020, "2020–2021")
      {:ok, sched_b} = Schedules.upsert_schedule(2021, "2021–2022")

      {:ok, emily_a} =
        Residents.insert_resident(sched_a.id, %{
          position_code: "R3-1",
          residency_year: 3,
          schedule_number: 1,
          name: "Emily K"
        })

      {:ok, _emily_b} =
        Residents.insert_resident(sched_b.id, %{
          position_code: "R4-1",
          residency_year: 4,
          schedule_number: 1,
          name: "Emily K"
        })

      {:ok, clare_a} =
        Residents.insert_resident(sched_a.id, %{
          position_code: "R2-1",
          residency_year: 2,
          schedule_number: 1,
          name: "Clare M"
        })

      {:ok, _} =
        Rotations.insert_rotations(emily_a.id, [
          %{
            slot_index: 0,
            start_date: ~D[2020-07-01],
            end_date: ~D[2020-07-14],
            rotation_type: :night_float
          }
        ])

      rotation = Rotations.list_rotations_for_resident(emily_a.id) |> hd()

      {:ok, view, _html} = live(conn, "/admin")
      %{view: view, rotation: rotation, clare_a: clare_a}
    end

    test "selecting a rotation populates covering residents from its own schedule only", %{
      view: view,
      rotation: rotation,
      clare_a: clare_a
    } do
      html =
        view
        |> element("form[phx-change='override_change']")
        |> render_change(%{
          "rotation_type" => "night_float",
          "start_date" => "2020-07-01",
          "end_date" => "2020-07-14",
          "rotation_id" => to_string(rotation.id),
          "covering_schedule_resident_id" => ""
        })

      # Clare M is in sched_a — should appear as a covering option
      assert html =~ clare_a.name
      # Emily K from sched_b (R4-1) should NOT appear in the covering dropdown
      refute html =~ "R4-1"
    end

    test "covering residents list is empty before a rotation is selected", %{view: view} do
      html =
        view
        |> element("form[phx-change='override_change']")
        |> render_change(%{
          "rotation_type" => "night_float",
          "start_date" => "2020-07-01",
          "end_date" => "2020-07-14",
          "rotation_id" => "",
          "covering_schedule_resident_id" => ""
        })

      refute html =~ "Clare M"
    end
  end

  describe "change admin password" do
    setup %{conn: conn} do
      conn = Plug.Test.init_test_session(conn, authenticated: true, admin: true)
      {:ok, view, html} = live(conn, "/admin")
      %{conn: conn, view: view, html: html}
    end

    test "renders the admin password card", %{html: html} do
      assert html =~ "Change Admin Password"
    end

    test "shows the default-password warning before the password is customized", %{html: html} do
      assert html =~ "default admin password is still in use"
    end

    test "changes the password and shows a success message", %{view: view} do
      html =
        view
        |> form("#admin-password-form-0", %{
          "current_password" => "admin",
          "new_password" => "newsecret99",
          "confirm_password" => "newsecret99"
        })
        |> render_submit()

      assert html =~ "Admin password updated."
      refute html =~ "default admin password is still in use"
      assert ResidencySchedule.Accounts.verify_admin_password("newsecret99")
    end

    test "shows an error when the confirmation does not match", %{view: view} do
      html =
        view
        |> form("#admin-password-form-0", %{
          "current_password" => "admin",
          "new_password" => "newsecret99",
          "confirm_password" => "different99"
        })
        |> render_submit()

      assert html =~ "New passwords do not match."
      refute ResidencySchedule.Accounts.admin_password_customized?()
    end

    test "shows an error when the current password is wrong", %{view: view} do
      html =
        view
        |> form("#admin-password-form-0", %{
          "current_password" => "wrong",
          "new_password" => "newsecret99",
          "confirm_password" => "newsecret99"
        })
        |> render_submit()

      assert html =~ "Current password is incorrect."
      refute ResidencySchedule.Accounts.admin_password_customized?()
    end

    test "shows an error when the new password is too short", %{view: view} do
      html =
        view
        |> form("#admin-password-form-0", %{
          "current_password" => "admin",
          "new_password" => "short",
          "confirm_password" => "short"
        })
        |> render_submit()

      assert html =~ "password:"
      refute ResidencySchedule.Accounts.admin_password_customized?()
    end
  end
end
