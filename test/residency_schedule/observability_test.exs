defmodule ResidencySchedule.ObservabilityTest do
  use ExUnit.Case, async: false

  import ResidencySchedule.OtelHelpers

  alias ResidencySchedule.Observability

  require OpenTelemetry.Tracer, as: Tracer

  doctest ResidencySchedule.Observability

  setup :capture_spans

  describe "setup/0" do
    test "returns :ok and is safe to call repeatedly" do
      assert Observability.setup() == :ok
      assert Observability.setup() == :ok
    end

    test "attaches the bandit, phoenix + liveview, and ecto handlers" do
      Observability.setup()

      handler_ids = for %{id: id} <- :telemetry.list_handlers([]), do: id

      assert {OpentelemetryPhoenix, :endpoint_start} in handler_ids
      assert {OpentelemetryPhoenix, :router_dispatch_start} in handler_ids
      assert {OpentelemetryPhoenix, :live_view} in handler_ids
      assert {OpentelemetryEcto, [:residency_schedule, :repo, :query]} in handler_ids
      assert Enum.any?(handler_ids, &match?({OpentelemetryBandit, _}, &1))
    end
  end

  describe "stamp_journey/2" do
    test "stamps session.id and enduser.id on the active span" do
      Tracer.with_span "journey-test" do
        assert Observability.stamp_journey("abc-session", 42) == :ok
      end

      attributes = span_attributes(await_span("journey-test"))
      assert attributes["session.id"] == "abc-session"
      assert attributes["enduser.id"] == "42"
    end

    test "stamps only session.id for anonymous visitors" do
      Tracer.with_span "anon-journey-test" do
        Observability.stamp_journey("abc-session", nil)
      end

      attributes = span_attributes(await_span("anon-journey-test"))
      assert attributes["session.id"] == "abc-session"
      refute Map.has_key?(attributes, "enduser.id")
    end

    test "stamps no span attributes when session_id is nil" do
      Tracer.with_span "no-session-test" do
        Observability.stamp_journey(nil, nil)
      end

      assert span_attributes(await_span("no-session-test")) == %{}
    end

    test "sets session and user Logger metadata" do
      Observability.stamp_journey("abc-session", 7)

      assert Logger.metadata()[:session_id] == "abc-session"
      assert Logger.metadata()[:user_id] == 7
    end

    test "removes stale user metadata when user_id is nil" do
      Logger.metadata(user_id: 99)

      Observability.stamp_journey("abc-session", nil)

      refute Keyword.has_key?(Logger.metadata(), :user_id)
      assert Logger.metadata()[:session_id] == "abc-session"
    end

    test "is a no-op on spans when called outside any span" do
      assert Observability.stamp_journey("abc-session", 42) == :ok
    end
  end
end
