defmodule ResidencyScheduleWeb.DemoModeTest do
  use ResidencyScheduleWeb.ConnCase

  import Phoenix.LiveViewTest

  alias ResidencyScheduleWeb.Plugs.RequireAuth

  describe "RequireAuth.call/2 in demo mode" do
    test "admits an anonymous visitor as the demo user" do
      set_demo_mode(true)

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> RequireAuth.call([])

      refute conn.halted
      assert conn.assigns.current_user.role == :resident
      assert conn.assigns.current_user.id == nil
    end

    test "still halts an anonymous visitor when demo mode is off" do
      set_demo_mode(false)

      conn =
        build_conn()
        |> Plug.Test.init_test_session(%{})
        |> RequireAuth.call([])

      assert conn.halted
      assert redirected_to(conn) == "/login"
    end
  end

  describe "live navigation in demo mode" do
    # The router plug only guards the initial request; the on_mount hook has to
    # bypass too or live navigation would bounce a demo visitor to /login.
    test "mounts an authenticated LiveView with no session" do
      set_demo_mode(true)
      seed_schedule()

      {:ok, _view, html} = live(build_conn(), "/schedule")

      assert html =~ "Schedule:"
    end

    test "redirects to /login without demo mode" do
      set_demo_mode(false)

      assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), "/schedule")
    end

    test "keeps admin routes closed to the demo visitor" do
      set_demo_mode(true)

      # RequireAdmin rejects on the session before the on_mount hook runs, so
      # the demo bypass never widens /admin/*.
      assert {:error, {:redirect, %{to: "/login"}}} = live(build_conn(), "/admin")
    end
  end

  describe "writes refused in demo mode" do
    setup do
      set_demo_mode(true)
      seed_schedule()
      %{schedule: hd(ResidencySchedule.Schedules.list_schedules())}
    end

    test "delete_schedule keeps the schedule", %{schedule: schedule} do
      {:ok, view, _html} = live(build_conn(), "/schedule")

      render_submit(view, "delete_schedule", %{
        "schedule_id" => to_string(schedule.id),
        "password" => "whatever"
      })

      assert ResidencySchedule.Schedules.list_schedules() != []
    end

    test "request_delete never opens the confirm form", %{schedule: schedule} do
      {:ok, view, _html} = live(build_conn(), "/schedule")

      html = render_click(view, "request_delete", %{"id" => to_string(schedule.id)})

      refute html =~ ~s(phx-submit="delete_schedule")
    end

    test "the walkthrough auto-starts for a demo visitor" do
      {:ok, _view, html} = live(build_conn(), "/")

      assert html =~ ~s(data-auto-start="true")
      assert html =~ ~s(data-demo-mode="true")
    end

    test "tour_completed does not raise on the unpersisted demo user" do
      {:ok, view, _html} = live(build_conn(), "/schedule")

      assert render_hook(view, "tour_completed", %{})
    end
  end
end
