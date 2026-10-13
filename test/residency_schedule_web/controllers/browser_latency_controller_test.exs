defmodule ResidencyScheduleWeb.BrowserLatencyControllerTest do
  use ResidencyScheduleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias ResidencySchedule.Observability

  doctest ResidencyScheduleWeb.BrowserLatencyController

  @event [:browser, :live_view, :round_trip]
  @operations ~w(initial patch navigate event page_load)
  @path "/observability/browser-latency"

  setup :authenticate_session

  setup do
    handler = {__MODULE__, make_ref()}
    owner = self()

    :ok =
      :telemetry.attach(
        handler,
        @event,
        fn event, measurements, metadata, _ ->
          send(owner, {:latency, event, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  test "authenticated CSRF-protected ingestion emits only bounded browser measurements", %{
    conn: conn
  } do
    for view <- ~w(calendar schedule),
        operation <- @operations,
        duration <- [0, 1234.5, 60_000] do
      sample = %{"view" => view, "operation" => operation, "duration_ms" => duration}
      assert {:ok, ^sample} = Observability.browser_latency_sample(sample)

      response = conn |> csrf_conn() |> post(@path, Jason.encode!(sample))
      assert response(response, 204) == ""

      assert_receive {:latency, @event, %{duration_ms: ^duration},
                      %{view: ^view, operation: ^operation}}
    end
  end

  test "invalid and extra inputs do not emit telemetry", %{conn: conn} do
    valid = %{"view" => "calendar", "operation" => "event", "duration_ms" => 12}

    invalid =
      Enum.map([nil, "12", -1, 60_001, [], %{}, true], &Map.put(valid, "duration_ms", &1)) ++
        Enum.map([nil, "resident/private", "CALENDAR"], &Map.put(valid, "view", &1)) ++
        Enum.map([nil, "restore_prefs", "unknown"], &Map.put(valid, "operation", &1)) ++
        [
          Map.delete(valid, "duration_ms"),
          Map.put(valid, "url", "PRIVATE_RESIDENT_SENTINEL"),
          %{}
        ]

    for sample <- invalid do
      assert {:error, :invalid_sample} = Observability.browser_latency_sample(sample)
      response = conn |> csrf_conn() |> post(@path, Jason.encode!(sample))
      assert response.status == 422
      refute_receive {:latency, _, _, _}, 0
    end

    for sample <- [nil, [], "invalid", %{view: "calendar", operation: "event", duration_ms: 12}] do
      assert {:error, :invalid_sample} = Observability.record_browser_latency(sample)
      refute_receive {:latency, _, _, _}, 0
    end
  end

  test "missing authentication cannot submit samples" do
    sample = %{"view" => "calendar", "operation" => "navigate", "duration_ms" => 123}

    response =
      build_conn()
      |> Plug.Test.init_test_session(%{})
      |> csrf_conn()
      |> post(@path, Jason.encode!(sample))

    assert redirected_to(response) == "/login"
    refute_receive {:latency, _, _, _}, 0
  end

  test "missing or invalid CSRF token rejects authenticated ingestion", %{conn: conn} do
    for token <- [nil, "invalid-token"] do
      request =
        conn
        |> put_private(:plug_skip_csrf_protection, false)
        |> put_req_header("content-type", "application/json")
        |> put_req_header("accept", "text/html")

      request = if token, do: put_req_header(request, "x-csrf-token", token), else: request

      assert_error_sent 403, fn ->
        post(
          request,
          @path,
          Jason.encode!(%{view: "calendar", operation: "event", duration_ms: 12})
        )
      end

      refute_receive {:latency, _, _, _}, 0
    end
  end

  test "calendar and schedule controls enable public browser loading events", %{conn: conn} do
    seed_schedule()
    {:ok, calendar, _html} = live(conn, "/calendar?date=2023-07-05")
    assert has_element?(calendar, "#guided-tour[data-latency-view='calendar']")

    for event <- ~w(prev next today) do
      assert_browser_push(calendar, "#calendar-#{event}", event)
    end

    for mode <- ~w(month week day) do
      assert_browser_push(
        calendar,
        "#calendar-view-#{mode}[phx-value-view='#{mode}']",
        "set_view"
      )
    end

    assert_rendered_pushes(calendar)

    calendar
    |> element("button[data-action='toggle_filter_panel'][phx-value-panel='residents']")
    |> render_click()

    assert_rendered_pushes(calendar)

    calendar
    |> element("button[data-action='toggle_filter_panel'][phx-value-panel='rotations']")
    |> render_click()

    assert_rendered_pushes(calendar)

    calendar
    |> element("[data-action='select_day'][phx-value-date='2023-07-05']")
    |> render_click()

    assert_rendered_pushes(calendar)

    {:ok, schedule, _html} = live(conn, "/schedule")
    assert has_element?(schedule, "#guided-tour[data-latency-view='schedule']")

    for year <- ~w(all 1 2 3 4) do
      assert_browser_push(
        schedule,
        "#schedule-year-#{year}[phx-value-year='#{year}']",
        "filter_year"
      )
    end

    assert_rendered_pushes(schedule)
  end

  test "schedule deletion form uses the supported browser loading command", %{conn: conn} do
    seed_schedule()
    %{conn: admin_conn} = admin_authenticate_session(%{conn: conn})
    {:ok, schedule, _html} = live(admin_conn, "/schedule")
    schedule |> element("button[data-action='request_delete']") |> render_click()
    assert has_element?(schedule, "form[data-action='delete_schedule']")
    assert_rendered_pushes(schedule)
  end

  test "collector receives all ten bounded browser histogram series", %{conn: conn} do
    owner = self()

    plug = fn request, _ ->
      {:ok, body, request} = Plug.Conn.read_body(request)

      body =
        if Plug.Conn.get_req_header(request, "content-encoding") == ["gzip"],
          do: :zlib.gunzip(body),
          else: body

      send(owner, {:export, request.request_path, body})
      Plug.Conn.send_resp(request, 200, "")
    end

    server =
      start_supervised!({Bandit, plug: plug, ip: {127, 0, 0, 1}, port: 0, startup_log: false})

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    start_supervised!(
      {Observability,
       endpoint: "http://127.0.0.1:#{port}", token: "fake", environment: "test", flush_ms: 60_000}
    )

    for view <- ~w(calendar schedule), operation <- @operations do
      sample = %{view: view, operation: operation, duration_ms: 1234.5}
      response = conn |> csrf_conn() |> post(@path, Jason.encode!(sample))
      assert response.status == 204
    end

    for view <- [ResidencyScheduleWeb.CalendarLive.Index, ResidencyScheduleWeb.ScheduleLive.Index],
        operation <- [:mount, :handle_params, :handle_event, :render] do
      :telemetry.execute(
        [:phoenix, :live_view, operation, :stop],
        %{duration: System.convert_time_unit(12, :millisecond, :native)},
        %{
          socket: %Phoenix.LiveView.Socket{view: view},
          params: %{},
          session: %{},
          event: "probe",
          uri: nil
        }
      )
    end

    :telemetry.execute([:vm, :memory], %{total: 4096}, %{})
    :telemetry.execute([:vm, :total_run_queue_lengths], %{total: 3, cpu: 2, io: 1}, %{})

    # Ecto omits idle_time when the connection supplies no idle measurement.
    # Seed every defined database series explicitly for the cardinality contract.
    :telemetry.execute(
      [:residency_schedule, :repo, :query],
      %{total_time: 0, query_time: 0, queue_time: 0, decode_time: 0, idle_time: 0},
      %{}
    )

    Observability.flush()
    assert_receive {:export, "/v1/metrics", body}, 3000

    exported =
      body
      |> :otlp_shipper_metrics_service.decode_msg(
        :"opentelemetry.proto.collector.metrics.v1.ExportMetricsServiceRequest"
      )
      |> Map.fetch!(:resource_metrics)
      |> Enum.flat_map(& &1.scope_metrics)
      |> Enum.flat_map(& &1.metrics)

    metric = Enum.find(exported, &(&1.name == "browser.live_view.round_trip.duration"))

    assert Enum.reduce(exported, 0, fn metric, count ->
             {_type, data} = metric.data
             count + length(data.data_points)
           end) == 29

    assert metric.unit == "ms"
    assert {:histogram, %{data_points: points}} = metric.data
    assert length(points) == 10

    assert MapSet.new(Enum.map(points, &attributes(&1.attributes))) ==
             MapSet.new(
               for view <- ~w(calendar schedule),
                   operation <- @operations,
                   do: %{"view" => view, "operation" => operation}
             )

    for point <- points do
      assert point.count == 1
      assert point.sum == 1234.5
      assert Enum.sum(point.bucket_counts) == 1
    end
  end

  defp csrf_conn(conn) do
    Plug.CSRFProtection.delete_csrf_token()
    token = Plug.CSRFProtection.get_csrf_token()

    conn
    |> put_session("_csrf_token", Plug.CSRFProtection.dump_state())
    |> put_private(:plug_skip_csrf_protection, false)
    |> put_req_header("x-csrf-token", token)
    |> put_req_header("content-type", "application/json")
    |> put_req_header("accept", "text/html")
  end

  defp assert_browser_push(view, selector, event) do
    assert has_element?(view, selector)

    [encoded] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.attribute("phx-click")

    assert [["push", %{"event" => ^event, "page_loading" => true}]] = Jason.decode!(encoded)
  end

  defp assert_rendered_pushes(view) do
    controls =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(
        "#guided-tour [phx-click], #guided-tour [phx-submit], #guided-tour [phx-change]"
      )

    refute Enum.empty?(controls)

    for control <- controls do
      [event] = LazyHTML.attribute(control, "data-action")

      [encoded] =
        Enum.flat_map(~w(phx-click phx-submit phx-change), &LazyHTML.attribute(control, &1))

      assert [["push", %{"event" => ^event, "page_loading" => true}]] = Jason.decode!(encoded)
    end
  end

  defp attributes(values),
    do: Map.new(values, fn %{key: key, value: %{value: {_, value}}} -> {key, value} end)
end
