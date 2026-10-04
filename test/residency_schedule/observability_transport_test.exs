defmodule ResidencySchedule.ObservabilityTransportTest do
  use ExUnit.Case, async: false
  require Logger

  alias ResidencySchedule.Observability

  test "an untrappable request handler crash recovers registration and emits once" do
    baseline = handler_ids()
    endpoint = collector(200)

    supervisor =
      start_supervised!(
        {Observability, endpoint: endpoint, token: "fake", environment: "test", flush_ms: 60_000}
      )

    handler = Process.whereis(Observability.RequestHandler)
    monitor = Process.monitor(handler)
    Process.exit(handler, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^handler, :killed}

    children = Supervisor.which_children(supervisor)

    assert {Observability.RequestHandler, restarted, :worker, _} =
             List.keyfind(children, Observability.RequestHandler, 0)

    assert is_pid(restarted)
    refute restarted == handler
    :sys.get_state(restarted)

    assert :ok = emit_request()
    Observability.flush()
    exports = receive_exports()
    [resource_logs] = exports["/v1/logs"].resource_logs
    assert [_] = Enum.flat_map(resource_logs.scope_logs, & &1.log_records)
    [resource_spans] = exports["/v1/traces"].resource_spans
    assert [_] = Enum.flat_map(resource_spans.scope_spans, & &1.spans)
    assert :ok = stop_supervised(Observability)
    assert handler_ids() == baseline
  end

  test "stopping and restarting export removes handlers and prevents duplicate records" do
    baseline = handler_ids()
    endpoint = collector(200)
    opts = [endpoint: endpoint, token: "fake", environment: "test", flush_ms: 60_000]
    start_supervised!({Observability, opts})
    assert MapSet.size(handler_ids()) > MapSet.size(baseline)
    assert :ok = stop_supervised(Observability)
    assert handler_ids() == baseline

    start_supervised!({Observability, opts})
    emit_request()
    Observability.flush()
    exports = receive_exports()
    [resource_logs] = exports["/v1/logs"].resource_logs
    assert [_] = Enum.flat_map(resource_logs.scope_logs, & &1.log_records)
    [resource_spans] = exports["/v1/traces"].resource_spans
    assert [_] = Enum.flat_map(resource_spans.scope_spans, & &1.spans)
    [resource_metrics] = exports["/v1/metrics"].resource_metrics

    count =
      resource_metrics.scope_metrics
      |> Enum.flat_map(& &1.metrics)
      |> Enum.find(&(&1.name == "phoenix.endpoint.stop.count"))

    assert {:sum, %{data_points: [%{value: {:as_int, 1}}]}} = count.data
    assert :ok = stop_supervised(Observability)
    assert handler_ids() == baseline
  end

  test "collector failure does not take down request producers or supervision" do
    status = :atomics.new(1, [])
    :atomics.put(status, 1, 400)
    endpoint = collector(fn -> :atomics.get(status, 1) end)

    pid =
      start_supervised!(
        {Observability, endpoint: endpoint, token: "fake", environment: "test", flush_ms: 60_000}
      )

    monitor = Process.monitor(pid)
    assert :ok = emit_request()
    Observability.flush()
    assert map_size(receive_exports()) == 3
    :atomics.put(status, 1, 200)
    assert :ok = emit_request()
    Observability.flush()
    assert map_size(receive_exports()) == 3
    assert is_list(Supervisor.which_children(pid))
    refute_receive {:DOWN, ^monitor, :process, ^pid, _}, 100
    Process.demonitor(monitor, [:flush])
  end

  test "real OTLP transport exports only sanitized request summaries and aggregate measurements" do
    owner = self()

    plug = fn conn, _ ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      body =
        if Plug.Conn.get_req_header(conn, "content-encoding") == ["gzip"],
          do: :zlib.gunzip(body),
          else: body

      send(owner, {:export, conn.request_path, conn.req_headers, body})
      Plug.Conn.send_resp(conn, 200, "")
    end

    server =
      start_supervised!({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    start_supervised!(
      {Observability,
       endpoint: "http://127.0.0.1:#{port}",
       token: "fake-hub-token",
       environment: "test",
       flush_ms: 60_000}
    )

    secret = "PRIVATE_RESIDENT_AUTH_CHAT_SQL_SENTINEL"
    Logger.error(secret)

    conn =
      Plug.Test.conn("POST", "/residents/#{secret}?token=#{secret}")
      |> Plug.Conn.put_req_header("authorization", "Bearer #{secret}")
      |> Plug.Conn.assign(:resident, secret)
      |> Map.put(:status, 201)

    duration = System.convert_time_unit(12, :millisecond, :native)
    metadata = %{conn: conn, query: secret, params: [secret], result: secret, source: secret}
    :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: duration}, metadata)

    :telemetry.execute(
      [:residency_schedule, :repo, :query],
      %{total_time: duration, query_time: duration, queue_time: 0, decode_time: 0, idle_time: 0},
      metadata
    )

    :telemetry.execute([:vm, :memory], %{total: 4096}, metadata)
    :telemetry.execute([:vm, :total_run_queue_lengths], %{total: 3, cpu: 2, io: 1}, metadata)
    Observability.flush()

    exports =
      for _ <- 1..3 do
        assert_receive {:export, path, headers, body}, 3000
        assert {"authorization", "Bearer fake-hub-token"} in headers
        refute body =~ secret
        {path, decode(path, body)}
      end
      |> Map.new()

    assert Map.keys(exports) |> Enum.sort() == ["/v1/logs", "/v1/metrics", "/v1/traces"]

    [resource_logs] = exports["/v1/logs"].resource_logs
    assert_resource(resource_logs.resource)
    logs = Enum.flat_map(resource_logs.scope_logs, & &1.log_records)
    assert [log] = logs
    assert log.body.value == {:string_value, "HTTP request completed"}

    assert attributes(log.attributes) == %{
             "http.request.method" => "POST",
             "http.response.status_code" => 201
           }

    [resource_spans] = exports["/v1/traces"].resource_spans
    assert_resource(resource_spans.resource)
    assert [span] = Enum.flat_map(resource_spans.scope_spans, & &1.spans)
    assert span.name == "HTTP request"
    assert span.end_time_unix_nano - span.start_time_unix_nano == 12_000_000

    assert attributes(span.attributes) == %{
             "http.request.method" => "POST",
             "http.response.status_code" => 201
           }

    [resource_metrics] = exports["/v1/metrics"].resource_metrics
    assert_resource(resource_metrics.resource)

    metrics =
      resource_metrics.scope_metrics |> Enum.flat_map(& &1.metrics) |> Map.new(&{&1.name, &1})

    assert {:sum, %{data_points: [%{value: {:as_int, 1}}]}} =
             metrics["phoenix.endpoint.stop.count"].data

    assert {:histogram, %{data_points: [%{count: 1, sum: 12.0}]}} =
             metrics["phoenix.endpoint.stop.duration"].data

    assert {:histogram, %{data_points: [%{count: 1, sum: 12.0}]}} =
             metrics["residency_schedule.repo.query.total_time"].data

    assert {:gauge, %{data_points: [%{value: {:as_int, 3}}]}} =
             metrics["vm.total_run_queue_lengths.total"].data

    assert Map.has_key?(metrics, "vm.memory.total")

    for metric <- Map.values(metrics), {_type, data} = metric.data, point <- data.data_points do
      assert point.attributes == []
    end
  end

  defp assert_resource(resource) do
    attrs = attributes(resource.attributes)
    assert attrs["service.name"] == "residency-schedule"
    assert attrs["deployment.environment.name"] == "test"
  end

  defp handler_ids do
    [:phoenix, :endpoint, :stop]
    |> :telemetry.list_handlers()
    |> MapSet.new(& &1.id)
  end

  defp emit_request do
    conn = Plug.Test.conn("GET", "/") |> Map.put(:status, 200)
    :telemetry.execute([:phoenix, :endpoint, :stop], %{duration: 1}, %{conn: conn})
  end

  defp receive_exports do
    for _ <- 1..3 do
      assert_receive {:export, path, _, body}, 3000
      {path, decode(path, body)}
    end
    |> Map.new()
  end

  defp collector(status) do
    owner = self()

    plug = fn conn, _ ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      body =
        if Plug.Conn.get_req_header(conn, "content-encoding") == ["gzip"],
          do: :zlib.gunzip(body),
          else: body

      send(owner, {:export, conn.request_path, conn.req_headers, body})
      Plug.Conn.send_resp(conn, if(is_function(status), do: status.(), else: status), "")
    end

    server =
      start_supervised!({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)
    "http://127.0.0.1:#{port}"
  end

  defp attributes(values),
    do: Map.new(values, fn %{key: key, value: %{value: {_, value}}} -> {key, value} end)

  defp decode("/v1/logs", body),
    do:
      :otlp_shipper_logs_service.decode_msg(
        body,
        :"opentelemetry.proto.collector.logs.v1.ExportLogsServiceRequest"
      )

  defp decode("/v1/metrics", body),
    do:
      :otlp_shipper_metrics_service.decode_msg(
        body,
        :"opentelemetry.proto.collector.metrics.v1.ExportMetricsServiceRequest"
      )

  defp decode("/v1/traces", body),
    do:
      :otlp_shipper_trace_service.decode_msg(
        body,
        :"opentelemetry.proto.collector.trace.v1.ExportTraceServiceRequest"
      )
end
