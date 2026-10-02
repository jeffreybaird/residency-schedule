defmodule ResidencyScheduleWeb.AdminLiveTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest

  alias ResidencySchedule.{Residents, Rotations, Schedules}

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

      html =
        view
        |> element("button[phx-click='request_delete'][phx-value-id='#{schedule.id}']")
        |> render_click()

      assert html =~ "Confirm"
      assert html =~ "Cancel"
    end

    test "cancel_delete hides confirmation UI", %{view: view} do
      schedule = List.first(ResidencySchedule.Schedules.list_schedules())

      view
      |> element("button[phx-click='request_delete'][phx-value-id='#{schedule.id}']")
      |> render_click()

      view |> element("button[phx-click='cancel_delete']") |> render_click()
      refute has_element?(view, "button[phx-click='confirm_delete']")
    end

    test "confirm_delete removes the schedule", %{view: view} do
      schedule = List.first(ResidencySchedule.Schedules.list_schedules())

      view
      |> element("button[phx-click='request_delete'][phx-value-id='#{schedule.id}']")
      |> render_click()

      html = view |> element("button[phx-click='confirm_delete']") |> render_click()
      refute html =~ "Delete a Schedule"
    end
  end

  describe "override form — covering residents scoped to rotation's schedule" do
    setup %{conn: conn} do
      %{conn: conn} = admin_authenticate_session(%{conn: conn})

      # Two schedules with a resident named "Nora K" in each — same person, different years
      {:ok, sched_a} = Schedules.upsert_schedule(2020, "2020–2021")
      {:ok, sched_b} = Schedules.upsert_schedule(2021, "2021–2022")

      {:ok, emily_a} =
        Residents.insert_resident(sched_a.id, %{
          position_code: "R3-1",
          residency_year: 3,
          schedule_number: 1,
          name: "Nora K"
        })

      {:ok, _emily_b} =
        Residents.insert_resident(sched_b.id, %{
          position_code: "R4-1",
          residency_year: 4,
          schedule_number: 1,
          name: "Nora K"
        })

      {:ok, clare_a} =
        Residents.insert_resident(sched_a.id, %{
          position_code: "R2-1",
          residency_year: 2,
          schedule_number: 1,
          name: "Isolde M"
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

      # Isolde M is in sched_a — should appear as a covering option
      assert html =~ clare_a.name
      # Nora K from sched_b (R4-1) should NOT appear in the covering dropdown
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

      refute html =~ "Isolde M"
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

  describe "pending user approval" do
    setup %{conn: conn} do
      %{conn: conn} = admin_authenticate_session(%{conn: conn})
      %{conn: conn}
    end

    test "shows Approve and Deny buttons for a pending user", %{conn: conn} do
      {:ok, pending} = ResidencySchedule.Accounts.create_user(%{email: "pending@gmail.com"})

      {:ok, view, html} = live(conn, "/admin")

      assert html =~ "Pending Approval"
      assert html =~ "pending@gmail.com"
      assert has_element?(view, "button[phx-click='approve_user'][phx-value-id='#{pending.id}']")
      assert has_element?(view, "button[phx-click='deny_user'][phx-value-id='#{pending.id}']")
    end

    test "denying a pending user removes them from the pending list but keeps the record", %{
      conn: conn
    } do
      {:ok, pending} = ResidencySchedule.Accounts.create_user(%{email: "pending@gmail.com"})

      {:ok, view, _html} = live(conn, "/admin")

      html =
        view
        |> element("button[phx-click='deny_user'][phx-value-id='#{pending.id}']")
        |> render_click()

      refute html =~ "pending@gmail.com"
      assert ResidencySchedule.Accounts.get_user!(pending.id).denied == true
    end

    test "links to the separate denied-users page", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin")
      assert has_element?(view, "a[href='/admin/denied']")
    end
  end

  describe "pending change requests" do
    setup %{conn: conn} do
      %{conn: conn, user: admin} = admin_authenticate_session(%{conn: conn})
      fixtures = ResidencySchedule.ScheduleFixtures.seed_mini_schedule()
      clare_user = ResidencySchedule.ScheduleFixtures.resident_user(fixtures.clare)
      tiff_ob = ResidencySchedule.ScheduleFixtures.rotation_on(fixtures.tiff, ~D[2026-07-15])

      {:ok, request} =
        ResidencySchedule.ChangeRequests.request_coverage(clare_user, %{
          rotation_id: tiff_ob.id,
          covering_schedule_resident_id: fixtures.clare.id,
          start_date: ~D[2026-07-15],
          end_date: ~D[2026-07-16],
          note: "swap for clinic"
        })

      %{conn: conn, admin: admin, request: request, clare_user: clare_user}
    end

    test "lists the request with both residents and the note", %{
      conn: conn,
      request: request,
      clare_user: clare_user
    } do
      {:ok, view, html} = live(conn, "/admin")
      assert html =~ "Pending Change Requests (1)"
      assert html =~ "Tiff"
      assert html =~ "Clare"
      assert html =~ "swap for clinic"
      assert html =~ clare_user.email

      assert has_element?(
               view,
               "button[phx-click='approve_request'][phx-value-id='#{request.id}']"
             )

      assert has_element?(view, "button[phx-click='deny_request'][phx-value-id='#{request.id}']")
    end

    test "approving creates an override and clears the list", %{conn: conn, request: request} do
      {:ok, view, _html} = live(conn, "/admin")

      html =
        view
        |> element("button[phx-click='approve_request'][phx-value-id='#{request.id}']")
        |> render_click()

      refute html =~ "Pending Change Requests"
      assert html =~ "Active Overrides (1)"
      assert ResidencySchedule.ChangeRequests.get_request(request.id).status == :approved
    end

    test "denying records the decision without an override", %{conn: conn, request: request} do
      {:ok, view, _html} = live(conn, "/admin")

      html =
        view
        |> element("button[phx-click='deny_request'][phx-value-id='#{request.id}']")
        |> render_click()

      refute html =~ "Pending Change Requests"
      refute html =~ "Active Overrides"
      assert ResidencySchedule.ChangeRequests.get_request(request.id).status == :denied
    end

    test "acting on an already-decided request shows an error", %{
      conn: conn,
      request: request,
      clare_user: clare_user
    } do
      {:ok, view, _html} = live(conn, "/admin")
      {:ok, _} = ResidencySchedule.ChangeRequests.cancel_request(clare_user, request.id)

      # PubSub has already removed the row, so drive the event directly to
      # simulate a click that raced the cancellation.
      html = render_click(view, "approve_request", %{"id" => Integer.to_string(request.id)})

      assert html =~ "already decided"
      assert html =~ "Pending Change Requests (0)"
    end

    test "section is hidden when nothing is pending", %{
      conn: conn,
      admin: admin,
      request: request
    } do
      {:ok, _} = ResidencySchedule.ChangeRequests.deny_request(admin, request.id)
      {:ok, _view, html} = live(conn, "/admin")
      refute html =~ "Pending Change Requests"
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
