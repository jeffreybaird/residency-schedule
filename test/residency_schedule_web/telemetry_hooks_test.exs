defmodule ResidencyScheduleWeb.TelemetryHooksTest do
  use ResidencyScheduleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import ResidencySchedule.OtelHelpers

  alias ResidencyScheduleWeb.TelemetryHooks

  setup :authenticate_session
  setup :capture_spans

  @session_id "11111111-2222-3333-4444-555555555555"
  @view_prefix "ResidencyScheduleWeb.CalendarLive.Index"

  defp put_journey_session(conn) do
    Plug.Test.init_test_session(conn, telemetry_session_id: @session_id)
  end

  describe "journey identifiers on LiveView spans" do
    test "mount span carries session.id and enduser.id", %{conn: conn, user: user} do
      {:ok, _view, _html} = live(put_journey_session(conn), "/calendar")

      attributes = span_attributes(await_span("#{@view_prefix}.mount"))
      assert attributes["session.id"] == @session_id
      assert attributes["enduser.id"] == to_string(user.id)
    end

    test "handle_params span carries session.id and enduser.id", %{conn: conn, user: user} do
      {:ok, _view, _html} = live(put_journey_session(conn), "/calendar")

      attributes = span_attributes(await_span("#{@view_prefix}.handle_params"))
      assert attributes["session.id"] == @session_id
      assert attributes["enduser.id"] == to_string(user.id)
    end

    test "handle_event span carries session.id and enduser.id", %{conn: conn, user: user} do
      seed_schedule()
      {:ok, view, _html} = live(put_journey_session(conn), "/calendar")

      view |> element("button[phx-click='next']") |> render_click()

      attributes = span_attributes(await_span("#{@view_prefix}.handle_event#next"))
      assert attributes["session.id"] == @session_id
      assert attributes["enduser.id"] == to_string(user.id)
    end

    test "assigns the telemetry session id at mount", %{conn: conn} do
      {:ok, view, _html} = live(put_journey_session(conn), "/calendar")

      assert :sys.get_state(view.pid).socket.assigns.telemetry_session_id == @session_id
    end
  end

  describe "on_mount/4 outside the router" do
    test "skips the handle_params hook when the socket has no router" do
      socket = %Phoenix.LiveView.Socket{
        router: nil,
        private: %{lifecycle: %Phoenix.LiveView.Lifecycle{}}
      }

      session = %{"telemetry_session_id" => @session_id, "user_id" => 1}

      assert {:cont, socket} = TelemetryHooks.on_mount(:telemetry_context, %{}, session, socket)

      lifecycle = socket.private.lifecycle
      assert [%{id: :telemetry_context_event}] = lifecycle.handle_event
      assert lifecycle.handle_params == []
    end
  end
end
