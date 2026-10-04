defmodule ResidencySchedule.ObservabilityTest do
  use ExUnit.Case, async: false

  alias ResidencySchedule.Observability

  setup do
    previous = Application.get_env(:residency_schedule, :observability)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:residency_schedule, :observability, previous),
        else: Application.delete_env(:residency_schedule, :observability)
    end)
  end

  test "export supervision is opt-in" do
    Application.delete_env(:residency_schedule, :observability)
    assert Observability.children() == []
    Application.put_env(:residency_schedule, :observability, enabled: false)
    assert Observability.children() == []

    config = [
      enabled: true,
      endpoint: "https://otel.example.test",
      token: "fake",
      environment: "production"
    ]

    Application.put_env(:residency_schedule, :observability, config)
    assert [{Observability, ^config}] = Observability.children()
  end

  test "request attributes allow only bounded method and status" do
    conn = Plug.Test.conn("GET", "/resident/private?token=secret") |> Map.put(:status, 200)

    assert Observability.request_attributes(%{conn: conn, secret: "private"}) == %{
             "http.request.method" => "GET",
             "http.response.status_code" => 200
           }

    for method <- ~w(GET HEAD POST PUT DELETE CONNECT OPTIONS TRACE PATCH) do
      assert Observability.request_attributes(%{conn: %{conn | method: method}})[
               "http.request.method"
             ] == method
    end

    for status <- [nil, "200", 99, 600] do
      assert Observability.request_attributes(%{conn: %{conn | method: "secret", status: status}}) ==
               %{
                 "http.request.method" => "_OTHER"
               }
    end

    assert Observability.request_attributes(%{}) == %{"http.request.method" => "_OTHER"}
  end

  test "exported metric definitions are tagless bounded aggregates" do
    metrics = Observability.metrics()
    assert Enum.all?(metrics, &(&1.tags == []))

    assert Enum.any?(
             metrics,
             &match?(%Telemetry.Metrics.Counter{event_name: [:phoenix, :endpoint, :stop]}, &1)
           )

    assert Enum.any?(
             metrics,
             &match?(
               %Telemetry.Metrics.Distribution{event_name: [:phoenix, :endpoint, :stop]},
               &1
             )
           )

    assert Enum.any?(
             metrics,
             &match?(
               %Telemetry.Metrics.Distribution{event_name: [:residency_schedule, :repo, :query]},
               &1
             )
           )

    assert Enum.any?(
             metrics,
             &match?(%Telemetry.Metrics.LastValue{event_name: [:vm, :memory]}, &1)
           )

    assert Enum.any?(
             metrics,
             &match?(
               %Telemetry.Metrics.LastValue{event_name: [:vm, :total_run_queue_lengths]},
               &1
             )
           )

    refute Enum.any?(metrics, &match?(%Telemetry.Metrics.Summary{}, &1))

    for %Telemetry.Metrics.Distribution{} = metric <- metrics do
      assert [_ | _] = metric.reporter_options[:buckets]
    end
  end
end
