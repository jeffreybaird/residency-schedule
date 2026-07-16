defmodule ResidencyScheduleWeb.Plugs.TelemetryContextTest do
  use ResidencyScheduleWeb.ConnCase, async: true

  alias ResidencyScheduleWeb.Plugs.TelemetryContext

  doctest ResidencyScheduleWeb.Plugs.TelemetryContext

  describe "call/2" do
    test "generates a telemetry session id on first visit", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(%{})
        |> TelemetryContext.call([])

      assert {:ok, _uuid} = Ecto.UUID.cast(get_session(conn, :telemetry_session_id))
    end

    test "reuses an existing telemetry session id", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(telemetry_session_id: "existing-session-id")
        |> TelemetryContext.call([])

      assert get_session(conn, :telemetry_session_id) == "existing-session-id"
    end

    test "sets session and user Logger metadata for a logged-in user", %{conn: conn} do
      conn =
        conn
        |> Plug.Test.init_test_session(user_id: 42)
        |> TelemetryContext.call([])

      assert Logger.metadata()[:session_id] == get_session(conn, :telemetry_session_id)
      assert Logger.metadata()[:user_id] == 42
    end

    test "leaves user metadata unset for anonymous visitors", %{conn: conn} do
      Logger.metadata(user_id: 99)

      conn
      |> Plug.Test.init_test_session(%{})
      |> TelemetryContext.call([])

      refute Keyword.has_key?(Logger.metadata(), :user_id)
      assert Logger.metadata()[:session_id]
    end
  end

  describe "browser pipeline integration" do
    test "public routes carry a telemetry session id", %{conn: conn} do
      conn = get(conn, "/login")

      assert {:ok, _uuid} = Ecto.UUID.cast(get_session(conn, :telemetry_session_id))
    end
  end
end
