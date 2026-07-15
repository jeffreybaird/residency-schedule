defmodule ResidencyScheduleWeb.AdminLiveTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest

  alias ResidencySchedule.{Schedules, Residents, Rotations}

  describe "access control" do
    test "redirects to /login when not logged in", %{conn: conn} do
      conn = get(conn, "/admin")
      assert redirected_to(conn) == "/login"
    end

    test "redirects an approved non-admin to the site root", %{conn: conn} do
      %{conn: conn} = authenticate_session(%{conn: conn})
      conn = get(conn, "/admin")
      assert redirected_to(conn) == "/"
    end
  end

  describe "admin page without schedules" do
    setup %{conn: conn} do
      %{conn: conn} = admin_authenticate_session(%{conn: conn})
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
      %{conn: conn} = admin_authenticate_session(%{conn: conn})
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
      %{conn: conn} = admin_authenticate_session(%{conn: conn})

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

  describe "role management" do
    setup %{conn: conn} do
      %{conn: conn, user: admin} = admin_authenticate_session(%{conn: conn})
      %{conn: conn, admin: admin}
    end

    test "renders a role selector for each approved user", %{conn: conn, admin: admin} do
      {:ok, _view, html} = live(conn, "/admin")
      assert html =~ "role-form-#{admin.id}"
    end

    test "promotes an approved user to admin via the selector", %{conn: conn} do
      {:ok, member} = ResidencySchedule.Accounts.create_user(%{email: "partner@gmail.com"})
      {:ok, member} = ResidencySchedule.Accounts.approve_user(member)

      {:ok, view, _html} = live(conn, "/admin")

      view
      |> form("#role-form-#{member.id}")
      |> render_change(%{"role" => "admin"})

      assert ResidencySchedule.Accounts.get_user!(member.id).role == :admin
    end

    test "shows an error when promoting a non-URMC user to resident", %{conn: conn} do
      {:ok, member} = ResidencySchedule.Accounts.create_user(%{email: "partner@gmail.com"})
      {:ok, member} = ResidencySchedule.Accounts.approve_user(member)

      {:ok, view, _html} = live(conn, "/admin")

      html =
        view
        |> form("#role-form-#{member.id}")
        |> render_change(%{"role" => "resident"})

      assert html =~ "resident role requires a URMC email address"
      assert ResidencySchedule.Accounts.get_user!(member.id).role == :user
    end

    test "refuses to demote the last admin", %{conn: conn, admin: admin} do
      {:ok, view, _html} = live(conn, "/admin")

      html =
        view
        |> form("#role-form-#{admin.id}")
        |> render_change(%{"role" => "user"})

      assert html =~ "Cannot remove the last admin."
      assert ResidencySchedule.Accounts.get_user!(admin.id).role == :admin
    end

    test "demotes an admin when another admin remains", %{conn: conn} do
      second_admin = create_admin()

      {:ok, view, _html} = live(conn, "/admin")

      view
      |> form("#role-form-#{second_admin.id}")
      |> render_change(%{"role" => "user"})

      assert ResidencySchedule.Accounts.get_user!(second_admin.id).role == :user
    end

    test "shows an error for an unrecognized role value", %{conn: conn} do
      {:ok, member} =
        ResidencySchedule.Accounts.create_user(%{email: "member@urmc.rochester.edu"})

      {:ok, view, _html} = live(conn, "/admin")

      html =
        view
        |> form("#role-form-#{member.id}")
        |> render_change(%{"role" => "superuser"})

      assert html =~ "Unknown role."
      assert ResidencySchedule.Accounts.get_user!(member.id).role == :resident
    end

    test "revoking an admin shows an error instead of locking them out", %{
      conn: conn,
      admin: admin
    } do
      {:ok, view, _html} = live(conn, "/admin")

      html =
        view
        |> element("button[phx-click='revoke_user'][phx-value-id='#{admin.id}']")
        |> render_click()

      assert html =~ "Admins cannot be revoked"
      assert ResidencySchedule.Accounts.get_user!(admin.id).approved == true
    end
  end

  describe "account password card without a password set" do
    setup %{conn: conn} do
      %{conn: conn, user: admin} = admin_authenticate_session(%{conn: conn})
      {:ok, view, html} = live(conn, "/admin")
      %{view: view, html: html, admin: admin}
    end

    test "renders the set-password state with a warning", %{html: html} do
      assert html =~ "Set My Password"
      assert html =~ "no password yet"
    end

    test "sets a password without requiring the current one", %{view: view, admin: admin} do
      html =
        view
        |> form("#account-password-form-0", %{
          "new_password" => "newsecret99",
          "confirm_password" => "newsecret99"
        })
        |> render_submit()

      assert html =~ "Your password has been updated."
      refute html =~ "no password yet"

      assert {:ok, _} =
               ResidencySchedule.Accounts.authenticate_by_password(admin.email, "newsecret99")
    end
  end

  describe "account password card with a password set" do
    setup %{conn: conn} do
      admin = create_admin("oldsecret99")
      conn = Plug.Test.init_test_session(conn, user_id: admin.id)
      {:ok, view, html} = live(conn, "/admin")
      %{view: view, html: html, admin: admin}
    end

    test "renders the change-password state without a warning", %{html: html} do
      assert html =~ "Change My Password"
      refute html =~ "no password yet"
    end

    test "changes the password with the correct current password", %{view: view, admin: admin} do
      html =
        view
        |> form("#account-password-form-0", %{
          "current_password" => "oldsecret99",
          "new_password" => "newsecret99",
          "confirm_password" => "newsecret99"
        })
        |> render_submit()

      assert html =~ "Your password has been updated."

      assert {:ok, _} =
               ResidencySchedule.Accounts.authenticate_by_password(admin.email, "newsecret99")
    end

    test "shows an error when the current password is wrong", %{view: view, admin: admin} do
      html =
        view
        |> form("#account-password-form-0", %{
          "current_password" => "wrong",
          "new_password" => "newsecret99",
          "confirm_password" => "newsecret99"
        })
        |> render_submit()

      assert html =~ "Current password is incorrect."

      assert {:ok, _} =
               ResidencySchedule.Accounts.authenticate_by_password(admin.email, "oldsecret99")
    end

    test "shows an error when the confirmation does not match", %{view: view, admin: admin} do
      html =
        view
        |> form("#account-password-form-0", %{
          "current_password" => "oldsecret99",
          "new_password" => "newsecret99",
          "confirm_password" => "different99"
        })
        |> render_submit()

      assert html =~ "New passwords do not match."

      assert {:ok, _} =
               ResidencySchedule.Accounts.authenticate_by_password(admin.email, "oldsecret99")
    end

    test "shows an error when the new password is too short", %{view: view, admin: admin} do
      html =
        view
        |> form("#account-password-form-0", %{
          "current_password" => "oldsecret99",
          "new_password" => "short",
          "confirm_password" => "short"
        })
        |> render_submit()

      assert html =~ "password:"

      assert {:ok, _} =
               ResidencySchedule.Accounts.authenticate_by_password(admin.email, "oldsecret99")
    end
  end
end
