defmodule ResidencyScheduleWeb.RenderDiagnosticsTest do
  use ResidencyScheduleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Phoenix.Channel.Server
  alias Phoenix.LiveView.{Lifecycle, Utils}
  alias Phoenix.Socket.Message
  alias Phoenix.Socket.V2.JSONSerializer
  alias ResidencySchedule.CountingJSON
  alias ResidencySchedule.Observability
  alias ResidencySchedule.Observability.RenderDiagnostics
  alias ResidencySchedule.Observability.Tracing
  alias ResidencyScheduleWeb.{CalendarLive, LiveSerializer, ScheduleLive}

  @secret "PRIVATE_RENDER_DIAGNOSTICS_SENTINEL"
  @flags ~w(name_col_px visible_resident_groups all_slots rotation_modal filter_year viewed_aca_year schedules unified_residents schedule_window)a

  setup :authenticate_session

  test "real connected renders export sequence, bounded causes, cached shape and process measurements",
       %{conn: conn} do
    seed_schedule()
    start_exporter()
    {:ok, view, _} = live(conn, "/schedule")
    view |> element("button[phx-value-year='2']") |> render_click()
    spans = flush_spans() |> Enum.filter(&(&1.name == "LiveView render"))
    assert length(spans) >= 2
    attrs = spans |> Enum.map(&attributes/1) |> Enum.sort_by(& &1["app.render.sequence"])
    first = hd(attrs)
    assert first["app.render.sequence"] == 1
    assert first["app.render.initial"] == true
    assert first["app.render.force"] == true
    assert first["app.render.trigger"] == "initial"

    for key <- ~w(app.rows.count app.slots.count app.cells.count app.cohorts.count) do
      assert is_integer(first[key]) and first[key] > 0
    end

    event = Enum.find(attrs, &(&1["app.render.event"] == "filter_year"))
    assert event
    assert event["app.render.initial"] == false
    assert event["app.render.trigger"] == "event"
    assert event["app.render.changed.filter_year"] == true
    assert event["app.render.changed.visible_resident_groups"] == true

    for item <- attrs do
      for key <-
            ~w(app.process.reductions.delta app.process.memory.before_bytes app.process.memory.after_bytes app.process.mailbox.before_count app.process.mailbox.after_count) do
        assert is_integer(item[key]) and item[key] >= 0
      end

      for flag <- @flags, do: assert(is_boolean(item["app.render.changed.#{flag}"]))
    end
  end

  test "start snapshot survives cleared stop assigns and excludes arbitrary keys and payloads" do
    start_exporter()
    socket = diagnostic_socket()
    changed = Map.new(@flags, &{&1, false}) |> Map.put(:private_payload, @secret)
    socket = %{socket | assigns: Map.put(socket.assigns, :__changed__, changed)}
    {:cont, socket} = Lifecycle.handle_event(@secret, %{@secret => @secret}, socket)
    render(socket, fn -> Enum.sum(1..1000) end, force?: false, changed?: true)
    [span] = flush_spans()
    attrs = attributes(span)
    assert attrs["app.render.trigger"] == "event"
    assert attrs["app.render.event"] == "_OTHER"
    assert attrs["app.render.force"] == false
    assert attrs["app.render.changed"] == true
    for flag <- @flags, do: assert(attrs["app.render.changed.#{flag}"] == true)
    assert attrs["app.rows.count"] == 2
    assert attrs["app.cells.count"] == 3
    assert attrs["app.slots.count"] == 4
    assert attrs["app.cohorts.count"] == 1
    assert attrs["app.rendered.rows.count"] == 1
    assert attrs["app.rendered.slots.count"] == 2
    assert attrs["app.rendered.cells.count"] == 1
    assert attrs["app.rendered.cohorts.count"] == 1

    assert is_integer(attrs["app.process.reductions.delta"]) and
             attrs["app.process.reductions.delta"] > 0

    refute Map.has_key?(attrs, "app.render.changed.private_payload")

    expected =
      ~w(view operation lifecycle db.query.count db.query.duration_ms db.queue.duration_ms db.decode.duration_ms db.total.duration_ms db.query.coverage app.spans.dropped app.render.sequence app.render.initial app.render.force app.render.changed app.render.trigger app.render.event deployment.sha app.rows.count app.slots.count app.cells.count app.cohorts.count app.process.reductions.delta app.process.memory.before_bytes app.process.memory.after_bytes app.process.mailbox.before_count app.process.mailbox.after_count) ++
        ~w(app.rendered.rows.count app.rendered.slots.count app.rendered.cells.count app.rendered.cohorts.count) ++
        Enum.map(@flags, &"app.render.changed.#{&1}")

    assert Enum.sort(Map.keys(attrs)) == Enum.sort(expected)
    assert map_size(attrs) == 39
    assert attrs["deployment.sha"] == Observability.deployment_version()
  end

  test "initial nil change map marks full recompute and next unrelated callback loses event cause" do
    start_exporter()
    socket = diagnostic_socket()
    socket = %{socket | assigns: Map.put(socket.assigns, :__changed__, nil)}
    render(socket, fn -> :ok end, force?: true, changed?: true)
    {:cont, socket} = Lifecycle.handle_event("filter_year", %{}, socket)
    render(socket, fn -> :ok end)
    {:cont, socket} = Lifecycle.handle_info({:private, @secret}, socket)
    render(socket, fn -> :ok end)
    spans = flush_spans() |> Enum.sort_by(&attributes(&1)["app.render.sequence"])
    assert Enum.map(spans, &attributes(&1)["app.render.sequence"]) == [1, 2, 3]
    for flag <- @flags, do: assert(attributes(hd(spans))["app.render.changed.#{flag}"] == true)
    assert attributes(Enum.at(spans, 1))["app.render.event"] == "filter_year"
    # Info hooks lack a native completion event, so a later internal render has
    # no proven causal relationship to the message that merely reached a hook.
    assert attributes(Enum.at(spans, 2))["app.render.trigger"] == "unknown"
    refute Map.has_key?(attributes(Enum.at(spans, 2)), "app.render.event")
  end

  test "actual Phoenix transport serialization counts encoded bytes once and consumes render correlation" do
    start_exporter()
    previous = Application.get_env(:phoenix, :json_library)
    Application.put_env(:phoenix, :json_library, CountingJSON)
    on_exit(fn -> Application.put_env(:phoenix, :json_library, previous) end)
    socket = diagnostic_socket()
    render(socket, fn -> :ok end)
    payload = %{0 => @secret, s: ["<div>", "</div>"]}
    Process.put(:diagnostic_encode_calls, 0)

    assert :ok =
             Server.push(
               self(),
               "private-join",
               "lv:private-topic",
               "diff",
               payload,
               LiveSerializer
             )

    assert_receive {:socket_push, :text, encoded}
    assert Process.get(:diagnostic_encode_calls) == 1
    bytes = IO.iodata_length(encoded)

    assert :ok =
             Server.push(self(), "private-join", "lv:private-topic", "diff", %{}, LiveSerializer)

    assert_receive {:socket_push, :text, _}
    spans = flush_spans()
    render_span = Enum.find(spans, &(&1.name == "LiveView render"))
    encodes = Enum.filter(spans, &(&1.name == "LiveView encode"))
    assert length(encodes) == 2
    correlated = Enum.find(encodes, &(attributes(&1)["app.encode.correlation"] == "render"))
    assert correlated
    assert correlated.trace_id == render_span.trace_id
    assert correlated.parent_span_id == render_span.span_id
    assert correlated.start_time_unix_nano >= render_span.end_time_unix_nano
    assert attributes(correlated)["app.render.sequence"] == 1
    assert attributes(correlated)["app.encode.bytes"] == bytes
    assert attributes(correlated)["app.encode.duration_ms"] >= 0
    assert Enum.any?(encodes, &(attributes(&1)["app.encode.correlation"] == "unavailable"))
  end

  test "no-op event completion and render exceptions cannot label a later internal forced render" do
    start_exporter()
    socket = diagnostic_socket()
    render(socket, fn -> :ok end)

    metadata = %{socket: socket, event: "close_rotation_details", params: %{}}

    :telemetry.span([:phoenix, :live_view, :handle_event], metadata, fn ->
      {:cont, unchanged} = Lifecycle.handle_event("close_rotation_details", %{}, socket)
      {:ok, %{metadata | socket: Utils.clear_changed(unchanged)}}
    end)

    # Internal events such as lv:clear-flash bypass the application callback hooks.
    render(socket, fn -> :ok end, force?: true, changed?: false)
    {:cont, changed} = Lifecycle.handle_event("filter_year", %{}, socket)
    assert_raise RuntimeError, @secret, fn -> render(changed, fn -> raise @secret end) end
    render(socket, fn -> :ok end, force?: true, changed?: false)

    spans = flush_spans() |> Enum.filter(&(&1.name == "LiveView render"))
    assert length(spans) == 4

    for sequence <- [2, 4] do
      span = Enum.find(spans, &(attributes(&1)["app.render.sequence"] == sequence))
      assert span
      assert attributes(span)["app.render.trigger"] == "unknown"
      refute Map.has_key?(attributes(span), "app.render.event")
    end
  end

  test "join encoding in another process is explicitly uncorrelated and callback without render clears pending context" do
    start_exporter()
    socket = diagnostic_socket()
    render(socket, fn -> :ok end)
    owner = self()

    Task.async(fn ->
      Server.reply(
        owner,
        "join",
        "ref",
        "lv:private",
        {:ok, %{rendered: %{0 => @secret}}},
        LiveSerializer
      )
    end)
    |> Task.await()

    assert_receive {:socket_push, :text, _}
    {:cont, _} = Lifecycle.handle_event("close_rotation_details", %{}, socket)
    Server.reply(self(), "join", "ref", "lv:private", {:ok, %{}}, LiveSerializer)
    assert_receive {:socket_push, :text, _}
    spans = flush_spans()
    encodes = Enum.filter(spans, &(&1.name == "LiveView encode"))
    assert length(encodes) == 2

    for span <- encodes do
      assert attributes(span)["app.encode.correlation"] == "unavailable"
      refute Map.has_key?(attributes(span), "app.render.sequence")
      assert span.parent_span_id in ["", <<0::64>>]
    end
  end

  test "calendar uses the same bounded diagnostics while unrelated views do not acquire shape state" do
    start_exporter()
    socket = diagnostic_socket(CalendarLive.Index)
    {:cont, socket} = Lifecycle.handle_event("next", %{"private" => @secret}, socket)
    render(socket, fn -> :ok end)
    [span] = flush_spans()
    assert attributes(span)["view"] == "calendar"
    assert attributes(span)["app.render.event"] == "next"

    other = %Phoenix.LiveView.Socket{
      view: ResidencyScheduleWeb.CompareLive.Index,
      private: %{lifecycle: Lifecycle.build([])}
    }

    assert {:cont, ^other} = RenderDiagnostics.on_mount(:default, %{}, %{}, other)
  end

  test "render and encoder exceptions preserve application errors and clear one-shot correlation" do
    start_exporter()
    socket = diagnostic_socket()
    render(socket, fn -> :ok end)
    assert_raise RuntimeError, @secret, fn -> render(socket, fn -> raise @secret end) end
    Server.push(self(), "join", "lv:private-topic", "diff", %{}, LiveSerializer)
    assert_receive {:socket_push, :text, _}
    render(socket, fn -> :ok end)

    assert_raise Protocol.UndefinedError, fn ->
      Server.push(self(), "join", "lv:private-topic", "diff", %{private: self()}, LiveSerializer)
    end

    Server.push(self(), "join", "lv:private-topic", "diff", %{}, LiveSerializer)
    assert_receive {:socket_push, :text, _}
    encodes = flush_spans() |> Enum.filter(&(&1.name == "LiveView encode"))
    successful = Enum.filter(encodes, &(attributes(&1)["app.encode.bytes"] != nil))
    assert length(successful) == 2
    assert Enum.all?(successful, &(attributes(&1)["app.encode.correlation"] == "unavailable"))
  end

  test "broken optional encoder diagnostics never prevent or retry the native encoder" do
    start_exporter()
    previous = Application.get_env(:phoenix, :json_library)
    Application.put_env(:phoenix, :json_library, CountingJSON)
    on_exit(fn -> Application.put_env(:phoenix, :json_library, previous) end)

    message = %Message{
      topic: "lv:private-topic",
      event: "diff",
      payload: %{0 => @secret}
    }

    expected = JSONSerializer.encode!(message)
    Process.put({RenderDiagnostics, :pending}, %{attributes: :invalid, span: :invalid})
    Process.put(:diagnostic_encode_calls, 0)
    assert LiveSerializer.encode!(message) == expected
    assert Process.get(:diagnostic_encode_calls) == 1
    assert Process.get({RenderDiagnostics, :pending}) == nil

    Process.put({RenderDiagnostics, :pending}, %{attributes: :invalid, span: :invalid})
    Process.put(:diagnostic_encode_calls, 0)

    assert_raise Protocol.UndefinedError, fn ->
      LiveSerializer.encode!(%{message | payload: %{private: self()}})
    end

    assert Process.get(:diagnostic_encode_calls) == 1
    assert Process.get({RenderDiagnostics, :pending}) == nil
  end

  test "malformed optional render state cannot detach the lifecycle telemetry handler" do
    start_exporter()
    socket = diagnostic_socket()
    malformed = %{socket | private: Map.put(socket.private, :render_counts, :invalid)}
    assert :application_result = render(malformed, fn -> :application_result end)
    handlers = :telemetry.list_handlers([:phoenix, :live_view, :render, :start])
    assert Enum.any?(handlers, &(&1.id == Tracing))
    render(socket, fn -> :ok end)
    spans = flush_spans()

    assert Enum.any?(
             spans,
             &(&1.name == "LiveView render" and attributes(&1)["app.rows.count"] == 2)
           )
  end

  defp diagnostic_socket(view \\ ScheduleLive.Index) do
    socket = %Phoenix.LiveView.Socket{
      view: view,
      transport_pid: self(),
      private: %{lifecycle: Lifecycle.build([])},
      assigns: %{__changed__: %{}, private_payload: @secret}
    }

    {:cont, socket} = RenderDiagnostics.on_mount(:default, %{}, %{}, socket)

    RenderDiagnostics.assign_counts(
      socket,
      [{2028, [%{cells: [{1, nil}, {1, nil}]}, %{cells: [{1, nil}]}]}],
      [1, 2, 3, 4],
      %{slots: [1, 2], groups: [{2028, [%{cells: [{2, nil}]}]}]}
    )
  end

  defp render(socket, fun, options \\ []) do
    metadata = %{
      socket: socket,
      force?: Keyword.get(options, :force?, false),
      changed?: Keyword.get(options, :changed?, true)
    }

    :telemetry.span([:phoenix, :live_view, :render], metadata, fn ->
      result = fun.()
      {result, %{metadata | socket: Utils.clear_changed(socket)}}
    end)
  end

  defp start_exporter do
    owner = self()

    plug = fn conn, _ ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)

      body =
        if Plug.Conn.get_req_header(conn, "content-encoding") == ["gzip"],
          do: :zlib.gunzip(body),
          else: body

      send(owner, {:diagnostic_export, conn.request_path, body})
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
    assert_receive {:diagnostic_export, "/v1/traces", body}, 3000
    refute body =~ @secret
    refute body =~ "private-topic"

    decoded =
      :otlp_shipper_trace_service.decode_msg(
        body,
        :"opentelemetry.proto.collector.trace.v1.ExportTraceServiceRequest"
      )

    for resource <- decoded.resource_spans do
      attrs =
        Map.new(resource.resource.attributes, fn %{key: key, value: %{value: {_, value}}} ->
          {key, value}
        end)

      assert attrs["service.version"] == Observability.deployment_version()
    end

    spans = decoded.resource_spans |> Enum.flat_map(& &1.scope_spans) |> Enum.flat_map(& &1.spans)

    for span <- spans do
      assert span.events == []
      assert span.links == []
    end

    spans
  end

  defp attributes(span),
    do: Map.new(span.attributes, fn %{key: key, value: %{value: {_, value}}} -> {key, value} end)
end
