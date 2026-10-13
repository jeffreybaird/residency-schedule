defmodule ResidencyScheduleWeb.ObservabilityLiveViewTest do
  use ResidencyScheduleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ResidencySchedule.Observability
  alias ResidencyScheduleWeb.{CalendarLive, ScheduleLive}

  @operations [:mount, :handle_params, :handle_event, :render]
  @views [{CalendarLive.Index, "calendar"}, {ScheduleLive.Index, "schedule"}]
  @buckets [1, 5, 10, 25, 50, 100, 250, 500, 1000, 5000]

  setup :authenticate_session

  test "OTLP histograms convert durations, preserve every series and exclude private metadata" do
    start_exporter()
    secret = "PRIVATE_RESIDENT_EVENT_URL_SESSION_SENTINEL"

    for operation <- @operations, {view, _label} <- @views, milliseconds <- [12, 5500] do
      metadata = %{
        socket: %Phoenix.LiveView.Socket{view: view, assigns: %{resident: secret}},
        event: secret,
        params: %{secret => secret},
        session: %{token: secret},
        uri: "https://example.test/#{secret}?token=#{secret}"
      }

      emit_operation(operation, milliseconds, metadata)
    end

    # Unrelated views cannot create more series. Malformed metadata is checked
    # directly against definitions, because Phoenix's own loggers require sockets.
    for operation <- @operations do
      metadata = %{
        socket: %Phoenix.LiveView.Socket{view: ResidencyScheduleWeb.CompareLive.Index},
        params: %{},
        session: %{},
        uri: nil,
        event: "ignored"
      }

      emit_operation(operation, 777, metadata)
    end

    # Exercise all existing series in the same interval as the eight LiveView series.
    conn = Plug.Test.conn("GET", "/") |> Map.put(:status, 200)

    :telemetry.execute(
      [:phoenix, :endpoint, :stop],
      %{duration: native(12)},
      %{conn: conn, options: [log: false]}
    )

    :telemetry.execute(
      [:residency_schedule, :repo, :query],
      %{
        total_time: native(12),
        query_time: native(12),
        queue_time: 0,
        decode_time: 0,
        idle_time: 0
      },
      %{}
    )

    :telemetry.execute([:vm, :memory], %{total: 4096}, %{})
    :telemetry.execute([:vm, :total_run_queue_lengths], %{total: 3, cpu: 2, io: 1}, %{})
    metrics = flush_metrics(secret)
    assert map_size(metrics) == 15

    for operation <- @operations do
      metric = Map.fetch!(metrics, metric_name(operation))
      assert metric.unit == "ms"
      assert {:histogram, %{data_points: points}} = metric.data
      assert length(points) == 2

      assert Enum.sort(Enum.map(points, &attributes(&1.attributes))) == [
               %{"view" => "calendar"},
               %{"view" => "schedule"}
             ]

      for point <- points do
        assert point.count == 2
        assert_in_delta point.sum, 5512.0, 0.001
        assert point.explicit_bounds == Enum.map(@buckets, &(&1 * 1.0))
        assert point.bucket_counts == [0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 1]
      end
    end

    assert {:sum, %{data_points: [%{value: {:as_int, 1}}]}} =
             metrics["phoenix.endpoint.stop.count"].data

    assert {:histogram, %{data_points: [%{sum: 12.0}]}} =
             metrics["residency_schedule.repo.query.total_time"].data

    assert {:gauge, %{data_points: [%{value: {:as_int, 3}}]}} =
             metrics["vm.total_run_queue_lengths.total"].data

    for {name, metric} <- metrics,
        not String.starts_with?(name, "phoenix.live_view."),
        {_type, data} = metric.data,
        point <- data.data_points do
      assert point.attributes == []
    end
  end

  test "real calendar and schedule navigation exports mount, params, event and render latency", %{
    conn: conn
  } do
    seed_schedule()
    start_exporter()

    {:ok, calendar, _html} = live(conn, "/calendar?date=2023-07-05")
    render_patch(calendar, "/calendar?date=2023-07-12")
    calendar |> element("button[data-action='next']") |> render_click()

    {:ok, schedule, _html} = live(conn, "/schedule")
    render_patch(schedule, "/schedule?latency_probe=1")
    schedule |> element("button[phx-value-year='2']") |> render_click()

    metrics = flush_metrics()

    for operation <- @operations do
      assert {:histogram, %{data_points: points}} =
               Map.fetch!(metrics, metric_name(operation)).data

      assert Enum.sort(Enum.map(points, &attributes(&1.attributes))) == [
               %{"view" => "calendar"},
               %{"view" => "schedule"}
             ]

      for point <- points do
        assert point.count > 0
        assert point.sum > 0
        assert Enum.sum(point.bucket_counts) == point.count
      end
    end
  end

  defp start_exporter do
    owner = self()

    plug = fn conn, _ ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      body =
        if Plug.Conn.get_req_header(conn, "content-encoding") == ["gzip"],
          do: :zlib.gunzip(body),
          else: body

      send(owner, {:export, conn.request_path, body})
      Plug.Conn.send_resp(conn, 200, "")
    end

    server =
      start_supervised!({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    start_supervised!(
      {Observability,
       endpoint: "http://127.0.0.1:#{port}", token: "fake", environment: "test", flush_ms: 60_000}
    )
  end

  defp flush_metrics(secret \\ nil) do
    Observability.flush()
    assert_receive {:export, "/v1/metrics", body}, 3000
    if secret, do: refute(body =~ secret)

    body
    |> :otlp_shipper_metrics_service.decode_msg(
      :"opentelemetry.proto.collector.metrics.v1.ExportMetricsServiceRequest"
    )
    |> Map.fetch!(:resource_metrics)
    |> Enum.flat_map(& &1.scope_metrics)
    |> Enum.flat_map(& &1.metrics)
    |> Map.new(&{&1.name, &1})
  end

  defp emit_operation(operation, milliseconds, metadata),
    do:
      :telemetry.execute(
        [:phoenix, :live_view, operation, :stop],
        %{duration: native(milliseconds)},
        metadata
      )

  defp native(milliseconds), do: System.convert_time_unit(milliseconds, :millisecond, :native)
  defp metric_name(operation), do: "phoenix.live_view.#{operation}.stop.duration"

  defp attributes(values),
    do: Map.new(values, fn %{key: key, value: %{value: {_, value}}} -> {key, value} end)
end
