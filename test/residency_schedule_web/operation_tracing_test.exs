defmodule ResidencyScheduleWeb.OperationTracingTest do
  use ResidencyScheduleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Ecto.Adapters.SQL.Sandbox
  alias ResidencySchedule.{Observability, Repo}
  alias ResidencySchedule.Observability.Tracing
  alias ResidencySchedule.Residents.ScheduleResident
  alias ResidencyScheduleWeb.{CalendarLive, Endpoint, ScheduleLive}

  @secret "PRIVATE_RESIDENT_SQL_AUTH_URL_EVENT_SENTINEL"
  @db_keys ~w(db.query.count db.query.duration_ms db.queue.duration_ms db.decode.duration_ms db.total.duration_ms)
  @count_keys ~w(app.rows.count app.residents.count app.slots.count app.cells.count app.results.count)
  @attribute_keys @db_keys ++
                    @count_keys ++
                    ~w(view operation lifecycle http.request.method http.response.status_code db.query.coverage app.spans.dropped)
  @phases ~w(schedule.load schedule.project schedule.residents schedule.slots schedule.rows schedule.cells calendar.project calendar.activities calendar.overrides calendar.options calendar.build)

  setup :authenticate_session

  setup do
    :otel_ctx.set_value(:operation_test_caller, @secret)
    :ok
  end

  test "real seeded static and connected navigation exports nested operations and useful phases",
       %{conn: conn} do
    seed_schedule()
    start_exporter()

    {:ok, calendar, _} = live(conn, "/calendar?date=2023-07-05&private=#{@secret}")
    render_patch(calendar, "/calendar?date=2023-07-12")
    calendar |> element("button[data-action='next']") |> render_click()
    {:ok, schedule, _} = live(conn, "/schedule")
    render_patch(schedule, "/schedule?private=#{@secret}")
    schedule |> element("button[phx-value-year='2']") |> render_click()

    spans = flush_spans()
    requests = Enum.filter(spans, &(&1.name == "HTTP request"))
    assert length(requests) == 2

    for view <- ~w(calendar schedule),
        lifecycle <- ~w(static connected),
        operation <-
          if(lifecycle == "static",
            do: ~w(mount handle_params),
            else: ~w(mount handle_params render)
          ) do
      matching =
        Enum.filter(spans, fn span ->
          attrs = attributes(span)

          attrs["view"] == view and attrs["lifecycle"] == lifecycle and
            attrs["operation"] == operation
        end)

      assert matching != [], "missing #{view} #{lifecycle} #{operation}"

      for span <- matching do
        assert span.name == "LiveView #{operation}"
        assert_diagnostics(span)

        if lifecycle == "static" do
          parent = Enum.find(requests, &(&1.span_id == span.parent_span_id))
          assert parent, "static callback must be a child of its live HTTP request"
          assert_nested(span, parent)
        else
          assert span.parent_span_id in ["", <<0::64>>]
          refute Enum.any?(requests, &(&1.trace_id == span.trace_id))
        end
      end
    end

    for view <- ~w(calendar schedule) do
      assert Enum.any?(spans, fn span ->
               attrs = attributes(span)

               attrs["view"] == view and attrs["operation"] == "handle_event" and
                 attrs["lifecycle"] == "connected"
             end)
    end

    for name <- @phases do
      matching = Enum.filter(spans, &(&1.name == name))
      assert matching != [], "missing useful phase #{name}"

      for span <- matching do
        parent = Enum.find(spans, &(&1.span_id == span.parent_span_id))
        assert parent
        assert_nested(span, parent)
        assert_diagnostics(span)
      end
    end

    for prefix <- ["schedule.", "calendar."] do
      assert Enum.any?(spans, fn span ->
               String.starts_with?(span.name, prefix) and
                 Enum.any?(
                   @count_keys,
                   &(is_number(attributes(span)[&1]) and attributes(span)[&1] > 0)
                 )
             end)
    end

    for key <- ["db.query.count", "db.query.duration_ms"] do
      assert Enum.any?(spans, &(is_number(attributes(&1)[key]) and attributes(&1)[key] > 0))
    end

    assert Enum.all?(spans, &(&1.events == [] and &1.links == []))
  end

  test "inclusive numeric diagnostics and fixed counts exclude arbitrary process queries", %{
    conn: conn
  } do
    start_exporter()
    previous = :otel_ctx.get_current()

    response =
      Tracing.request(conn, fn ->
        operation(:mount, ScheduleLive.Index, nil, fn ->
          assert [1, 2] ==
                   Tracing.phase(:schedule_load, fn ->
                     emit_query(2, 3, 4, 9)
                     Tracing.count(:rows, 2)
                     Tracing.count(:rows, -1)
                     Tracing.count(:unknown, 50)
                     Task.async(fn -> emit_query(100, 100, 100, 300) end) |> Task.await()
                     [1, 2]
                   end)

          emit_query(5, 0, 1, 6)
        end)

        %{conn | status: 200}
      end)

    assert response.status == 200
    assert :otel_ctx.get_current() == previous
    spans = flush_spans()
    assert length(spans) == 3
    request = Enum.find(spans, &(&1.name == "HTTP request"))
    mount = Enum.find(spans, &(&1.name == "LiveView mount"))
    phase = Enum.find(spans, &(&1.name == "schedule.load"))
    assert_nested(mount, request)
    assert_nested(phase, mount)
    for span <- [request, mount], do: assert_query_totals(span, 2, 7, 3, 5, 15)
    assert_query_totals(phase, 1, 2, 3, 4, 9)
    assert attributes(phase)["app.rows.count"] == 2
    refute Map.has_key?(attributes(phase), "app.unknown.count")
  end

  test "parallel Ecto preloads contribute to the phase and request counters", %{conn: conn} do
    start_exporter()
    owner = self()
    id = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        id,
        [:residency_schedule, :repo, :query],
        fn _, measurements, _, _ ->
          if self() != owner, do: send(owner, {:query_process, self(), measurements})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(id) end)

    Sandbox.unboxed_run(Repo, fn ->
      schedule =
        Repo.insert!(%ResidencySchedule.Schedules.Schedule{
          academic_year: 9091,
          label: "Synthetic trace test"
        })

      try do
        resident =
          Repo.insert!(%ResidencySchedule.Residents.Resident{
            name: @secret,
            calendar_token: Ecto.UUID.generate()
          })

        try do
          Tracing.request(conn, fn ->
            loaded =
              Tracing.phase(:schedule_residents, fn ->
                # Two independent nonempty associations force Ecto's parallel preload path.
                Repo.preload(
                  %ScheduleResident{id: -1, resident_id: resident.id, schedule_id: schedule.id},
                  [:resident, :schedule]
                )
              end)

            assert loaded.resident.name == @secret
            assert loaded.schedule.id == schedule.id
            %{conn | status: 200}
          end)
        after
          Repo.delete!(resident)
        end
      after
        Repo.delete!(schedule)
      end
    end)

    assert_receive {:query_process, first_pid, first}, 1000
    assert_receive {:query_process, second_pid, second}, 1000
    refute first_pid == owner
    refute second_pid == owner
    refute first_pid == second_pid
    spans = flush_spans()
    assert length(spans) == 2

    for span <- spans do
      attrs = attributes(span)
      assert attrs["db.query.count"] == 2

      for {key, measurement} <- [
            {"db.query.duration_ms", :query_time},
            {"db.queue.duration_ms", :queue_time},
            {"db.decode.duration_ms", :decode_time},
            {"db.total.duration_ms", :total_time}
          ] do
        expected =
          (Map.get(first, measurement, 0) + Map.get(second, measurement, 0)) /
            System.convert_time_unit(1, :millisecond, :native)

        assert_in_delta attrs[key], expected, 0.001
      end

      assert attrs["db.query.coverage"] == "current_process_and_preloads"
    end
  end

  test "phase and LiveView errors preserve exception semantics and restore context", %{conn: conn} do
    start_exporter()
    previous = :otel_ctx.get_current()

    Tracing.request(conn, fn ->
      parent = :otel_ctx.get_current()

      assert_raise RuntimeError, @secret, fn ->
        operation(:handle_event, CalendarLive.Index, self(), fn ->
          Tracing.phase(:calendar_build, fn -> raise @secret end)
        end)
      end

      assert :otel_ctx.get_current() == parent
      Tracing.phase(:calendar_options, fn -> :recovered end)
      %{conn | status: 200}
    end)

    assert :otel_ctx.get_current() == previous
    spans = flush_spans()

    for name <- ["LiveView handle_event", "calendar.build"] do
      span = Enum.find(spans, &(&1.name == name))
      assert span.status.code in [:STATUS_CODE_ERROR, 2]
      assert Map.get(span.status, :message, "") == ""
      assert span.events == []
    end

    request = Enum.find(spans, &(&1.name == "HTTP request"))
    assert_nested(Enum.find(spans, &(&1.name == "calendar.options")), request)
  end

  test "actual endpoint parser failure cleans context and records sanitized HTTP error" do
    start_exporter()
    previous = :otel_ctx.get_current()

    conn =
      Plug.Test.conn("POST", "/calendar?secret=#{@secret}", "{#{@secret}")
      |> put_req_header("content-type", "application/json")

    assert_raise Plug.Parsers.ParseError, fn -> Endpoint.call(conn, Endpoint.init([])) end
    assert :otel_ctx.get_current() == previous
    [span] = flush_spans()
    assert span.name == "HTTP request"
    assert span.status.code in [:STATUS_CODE_ERROR, 2]
    assert Map.get(span.status, :message, "") == ""
    assert span.events == []
  end

  test "span budget bounds phase export and resets for the next root", %{conn: conn} do
    start_exporter()
    previous = :otel_ctx.get_current()

    Tracing.request(conn, fn ->
      for _ <- 1..140, do: Tracing.phase(:schedule_cells, fn -> :ok end)
      %{conn | status: 200}
    end)

    assert :otel_ctx.get_current() == previous
    first = flush_spans()
    assert length(first) == 128
    assert attributes(Enum.find(first, &(&1.name == "HTTP request")))["app.spans.dropped"] == 13

    Tracing.request(conn, fn ->
      Tracing.phase(:schedule_cells, fn -> :ok end)
      %{conn | status: 200}
    end)

    assert length(flush_spans()) == 2
    assert :otel_ctx.get_current() == previous
  end

  test "disabled tracing and invalid phase labels preserve results and context", %{conn: conn} do
    previous = :otel_ctx.get_current()
    assert :ok == Tracing.request(conn, fn -> Tracing.phase(:schedule_load, fn -> :ok end) end)
    assert [] == Tracing.preload_options()
    assert :otel_ctx.get_current() == previous
    start_exporter()

    Tracing.request(conn, fn ->
      assert :ok == Tracing.phase(@secret, fn -> :ok end)
      assert :ok == Tracing.phase(:unknown, fn -> :ok end)
      %{conn | status: 200}
    end)

    assert [%{name: "HTTP request"}] = flush_spans()
    assert :otel_ctx.get_current() == previous
  end

  test "captured preload callback cannot charge a later operation", %{conn: conn} do
    start_exporter()
    owner = self()

    Tracing.request(conn, fn ->
      send(
        owner,
        {:preload_callback, Keyword.fetch!(Tracing.preload_options(), :on_preloader_spawn)}
      )

      %{conn | status: 200}
    end)

    assert_receive {:preload_callback, callback}
    assert_query_totals(hd(flush_spans()), 0, 0, 0, 0, 0)

    Tracing.request(conn, fn ->
      Task.async(fn ->
        callback.()
        emit_query(10, 10, 10, 30)
      end)
      |> Task.await()

      %{conn | status: 200}
    end)

    assert_query_totals(hd(flush_spans()), 0, 0, 0, 0, 0)
  end

  test "static-file early return restores context and exports a bounded request" do
    start_exporter()
    previous = :otel_ctx.get_current()
    conn = Plug.Test.conn("GET", "/robots.txt") |> Endpoint.call(Endpoint.init([]))
    assert conn.status == 200
    assert :otel_ctx.get_current() == previous
    [span] = flush_spans()
    assert span.name == "HTTP request"
    assert attributes(span)["http.response.status_code"] == 200
  end

  test "malformed and unmatched telemetry does not detach handlers or disturb active context", %{
    conn: conn
  } do
    start_exporter()
    previous = :otel_ctx.get_current()

    Tracing.request(conn, fn ->
      parent = :otel_ctx.get_current()

      metadata = %{
        socket: %Phoenix.LiveView.Socket{view: ScheduleLive.Index},
        telemetry_span_context: make_ref(),
        params: %{},
        event: "ignored",
        session: %{},
        uri: nil
      }

      :telemetry.execute([:phoenix, :live_view, :mount, :stop], %{duration: 1}, metadata)
      assert :otel_ctx.get_current() == parent
      operation(:mount, ResidencyScheduleWeb.CompareLive.Index, nil, fn -> :ignored end)
      assert :otel_ctx.get_current() == parent

      operation(:mount, ScheduleLive.Index, nil, fn ->
        :telemetry.execute(
          [:residency_schedule, :repo, :query],
          %{query_time: -1, queue_time: "private", decode_time: nil},
          %{query: @secret}
        )

        emit_query(1, 2, 3, 6)
      end)

      %{conn | status: 200}
    end)

    assert :otel_ctx.get_current() == previous
    spans = flush_spans()
    assert length(spans) == 2
    for span <- spans, do: assert_query_totals(span, 2, 1, 2, 3, 6)
  end

  test "explicit Ecto preload callbacks retain caller precedence", %{conn: conn} do
    start_exporter()
    owner = self()

    Sandbox.unboxed_run(Repo, fn ->
      Tracing.request(conn, fn ->
        Repo.preload(
          %ScheduleResident{id: -1, resident_id: -1, schedule_id: -1},
          [:resident, :schedule],
          on_preloader_spawn: fn -> send(owner, :custom_preloader) end
        )

        %{conn | status: 200}
      end)
    end)

    assert_receive :custom_preloader
    assert_receive :custom_preloader
    [span] = flush_spans()
    assert_query_totals(span, 0, 0, 0, 0, 0)
  end

  defp operation(kind, view, transport, fun) do
    metadata = %{
      socket: %Phoenix.LiveView.Socket{view: view, transport_pid: transport},
      params: %{@secret => @secret},
      event: @secret,
      session: %{},
      uri: @secret
    }

    :telemetry.span([:phoenix, :live_view, kind], metadata, fn -> {fun.(), metadata} end)
  end

  defp emit_query(query, queue, decode, total) do
    :telemetry.execute(
      [:residency_schedule, :repo, :query],
      %{
        query_time: native(query),
        queue_time: native(queue),
        decode_time: native(decode),
        total_time: native(total)
      },
      %{query: @secret, params: [@secret], result: @secret, source: @secret}
    )
  end

  defp native(ms), do: System.convert_time_unit(ms, :millisecond, :native)

  defp assert_query_totals(span, count, query, queue, decode, total) do
    attrs = attributes(span)
    assert attrs["db.query.count"] == count

    for {key, expected} <- Enum.zip(tl(@db_keys), [query, queue, decode, total]),
        do: assert_in_delta(attrs[key], expected, 0.001)

    assert attrs["db.query.coverage"] == "current_process_and_preloads"
  end

  defp assert_diagnostics(span) do
    attrs = attributes(span)

    for key <- @db_keys do
      assert is_number(attrs[key]), "missing numeric #{key} on #{span.name}"
      assert attrs[key] >= 0
    end

    assert attrs["db.query.coverage"] == "current_process_and_preloads"
  end

  defp assert_nested(child, parent) do
    assert child.parent_span_id == parent.span_id
    assert child.trace_id == parent.trace_id
    assert child.start_time_unix_nano >= parent.start_time_unix_nano
    assert child.end_time_unix_nano <= parent.end_time_unix_nano
    assert child.end_time_unix_nano >= child.start_time_unix_nano
  end

  defp attributes(span),
    do: Map.new(span.attributes, fn %{key: key, value: %{value: {_, value}}} -> {key, value} end)

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

  defp flush_spans do
    Observability.flush()
    assert_receive {:export, "/v1/traces", body}, 3000
    refute body =~ @secret
    refute body =~ "exception.message"
    refute body =~ "exception.stacktrace"
    assert_safe_other_exports()

    body
    |> :otlp_shipper_trace_service.decode_msg(
      :"opentelemetry.proto.collector.trace.v1.ExportTraceServiceRequest"
    )
    |> Map.fetch!(:resource_spans)
    |> Enum.flat_map(& &1.scope_spans)
    |> Enum.flat_map(& &1.spans)
    |> tap(fn spans ->
      for span <- spans do
        assert Map.keys(attributes(span)) -- @attribute_keys == [],
               "unexpected exported attributes on #{span.name}"

        assert span.events == []
        assert span.links == []
      end
    end)
  end

  defp assert_safe_other_exports do
    receive do
      {:export, path, body} when path != "/v1/traces" ->
        refute body =~ @secret
        assert_safe_other_exports()
    after
      0 -> :ok
    end
  end
end
