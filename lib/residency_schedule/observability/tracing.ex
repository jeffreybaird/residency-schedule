defmodule ResidencySchedule.Observability.Tracing do
  @moduledoc """
  Bounded operation spans with inclusive numeric query diagnostics.

  Only fixed labels and counts are exported. Ecto's default parallel preloads
  inherit counters; arbitrary tasks and explicitly overridden preload hooks do not.
  """
  alias ResidencySchedule.Observability

  @state {__MODULE__, :state}
  @queries {__MODULE__, :queries}
  @operations [:mount, :handle_params, :handle_event, :render]
  @phases %{
    schedule_load: "schedule.load",
    schedule_project: "schedule.project",
    schedule_residents: "schedule.residents",
    schedule_slots: "schedule.slots",
    schedule_rows: "schedule.rows",
    schedule_cells: "schedule.cells",
    calendar_project: "calendar.project",
    calendar_activities: "calendar.activities",
    calendar_overrides: "calendar.overrides",
    calendar_options: "calendar.options",
    calendar_build: "calendar.build"
  }
  @counts %{
    rows: "app.rows.count",
    residents: "app.residents.count",
    slots: "app.slots.count",
    cells: "app.cells.count",
    results: "app.results.count"
  }
  @timings [
    {:query_time, "db.query.duration_ms", 3},
    {:queue_time, "db.queue.duration_ms", 4},
    {:decode_time, "db.decode.duration_ms", 5},
    {:total_time, "db.total.duration_ms", 6}
  ]
  @span_budget 128

  @doc """
  Runs an HTTP operation, preserving its return value and exception semantics.

      iex> conn = Plug.Test.conn("GET", "/")
      iex> result = ResidencySchedule.Observability.Tracing.request(conn, fn -> %{conn | status: 200} end)
      iex> result.status
      200
  """
  def request(conn, fun) do
    within("HTTP request", Observability.request_attributes(%{conn: conn}), :server, fn ->
      result = fun.()
      set_http_attributes(%{conn: result})
      result
    end)
  end

  @doc """
  Measures an allowlisted application phase without changing its result.

      iex> ResidencySchedule.Observability.Tracing.phase(:schedule_rows, fn -> Enum.sum([1, 2, 3]) end)
      6
  """
  def phase(phase, fun) do
    case Map.fetch(@phases, phase) do
      {:ok, name} -> within(name, %{}, :internal, fun)
      :error -> fun.()
    end
  end

  @doc """
  Records a nonnegative count on the current phase using a fixed attribute key.

  Exempt from doctest: recording requires the supervised provider and a running
  collector. Integration tests verify the exported count on an active phase.
  """
  def count(kind, value) when is_integer(value) and value >= 0 do
    with {:ok, key} <- Map.fetch(@counts, kind),
         %{frames: [%{span: span} | _]} when not is_nil(span) <- Process.get(@state) do
      :otel_span.set_attributes(span, %{key => value})
    end

    :ok
  end

  def count(_, _), do: :ok

  @doc """
  Supplies Ecto's parallel preload hook with the active numeric counters.

  A hook retained past its operation cannot update closed counters. Exempt from
  doctest: the successful path requires a running provider, collector and database.
  Integration tests verify actual parallel preload queries in exported counters.
  """
  def preload_options do
    case active_counters() do
      [] ->
        []

      counters ->
        [
          on_preloader_spawn: fn ->
            Process.put(@queries, counters)
            :ok
          end
        ]
    end
  end

  @doc false
  def events do
    for(
      operation <- @operations,
      stage <- [:start, :stop, :exception],
      do: [:phoenix, :live_view, operation, stage]
    ) ++ [[:residency_schedule, :repo, :query]]
  end

  @doc false
  def handle_event([:residency_schedule, :repo, :query], measurements, _, _) do
    Enum.each(active_counters(), &add_query(&1, measurements))
    :ok
  end

  def handle_event([:phoenix, :live_view, operation, stage], _, metadata, _)
      when operation in @operations do
    with {:ok, attributes} <- live_attributes(metadata),
         {:ok, context} <- Map.fetch(metadata, :telemetry_span_context) do
      id = {operation, context}
      handle_lifecycle(stage, id, operation, attributes)
    end

    :ok
  end

  def handle_event(_, _, _, _), do: :ok

  @doc false
  def current_span do
    case Process.get(@state) do
      %{frames: frames} -> Enum.find_value(frames, & &1.span)
      _ -> nil
    end
  end

  @doc false
  def set_http_attributes(metadata) do
    case current_span() do
      nil -> :ok
      span -> :otel_span.set_attributes(span, Observability.request_attributes(metadata))
    end

    :ok
  end

  defp within(name, attributes, kind, fun) do
    if Process.whereis(Observability.RequestHandler) do
      id = make_ref()
      begin_span(id, name, attributes, kind)

      try do
        fun.()
      catch
        class, reason ->
          mark_error(id)
          :erlang.raise(class, reason, __STACKTRACE__)
      after
        finish_span(id)
      end
    else
      fun.()
    end
  end

  defp handle_lifecycle(:start, id, operation, attributes),
    do:
      begin_span(
        id,
        "LiveView #{operation}",
        Map.put(attributes, "operation", Atom.to_string(operation)),
        :internal
      )

  defp handle_lifecycle(:stop, id, _, _), do: finish_span(id)

  defp handle_lifecycle(:exception, id, _, _) do
    mark_error(id)
    finish_span(id)
  end

  defp begin_span(id, name, attributes, kind) do
    state = Process.get(@state, %{frames: [], created: 0, dropped: 0})
    previous_queries = Process.get(@queries)

    {frame, state} =
      if state.created < @span_budget do
        context = if state.frames == [], do: :otel_ctx.new(), else: :otel_ctx.get_current()

        tracer =
          :otel_tracer_provider.get_tracer(
            Observability.Traces,
            "residency-schedule",
            "0.1.0",
            :undefined
          )

        span =
          :otel_tracer.start_span(context, tracer, name, %{kind: kind, attributes: attributes})

        token = context |> :otel_tracer.set_current_span(span) |> :otel_ctx.attach()
        counters = :atomics.new(6, [])
        :atomics.put(counters, 1, 1)
        Process.put(@queries, [counters | active_counters()])

        {%{
           id: id,
           span: span,
           token: token,
           counters: counters,
           previous_queries: previous_queries
         }, %{state | created: state.created + 1}}
      else
        {%{id: id, span: nil, previous_queries: previous_queries},
         %{state | dropped: state.dropped + 1}}
      end

    Process.put(@state, %{state | frames: [frame | state.frames]})
    :ok
  end

  defp finish_span(id) do
    case Process.get(@state) do
      %{frames: [%{id: ^id} = frame | rest]} = state ->
        finish_frame(frame, rest, state.dropped)
        restore_queries(frame.previous_queries)

        if rest == [],
          do: Process.delete(@state),
          else: Process.put(@state, %{state | frames: rest})

      _ ->
        :ok
    end

    :ok
  end

  defp finish_frame(%{span: nil}, _, _), do: :ok

  defp finish_frame(frame, rest, dropped) do
    :atomics.put(frame.counters, 1, 0)
    :otel_span.set_attributes(frame.span, query_attributes(frame.counters))
    if rest == [], do: :otel_span.set_attributes(frame.span, %{"app.spans.dropped" => dropped})
    :otel_span.end_span(frame.span)
    :otel_ctx.detach(frame.token)
  end

  defp mark_error(id) do
    case Process.get(@state) do
      %{frames: [%{id: ^id, span: span} | _]} when not is_nil(span) ->
        :otel_span.set_status(span, :error)

      _ ->
        :ok
    end
  end

  defp restore_queries(nil), do: Process.delete(@queries)
  defp restore_queries(previous), do: Process.put(@queries, previous)

  defp active_counters,
    do: @queries |> Process.get([]) |> Enum.filter(&(:atomics.get(&1, 1) == 1))

  defp add_query(counters, measurements) do
    :atomics.add(counters, 2, 1)

    Enum.each(@timings, fn {measurement, _, index} ->
      case Map.get(measurements, measurement) do
        value when is_integer(value) and value >= 0 and value <= 1_000_000_000_000_000 ->
          :atomics.add(counters, index, value)

        _ ->
          :ok
      end
    end)
  end

  defp query_attributes(counters) do
    timings =
      Map.new(@timings, fn {_, key, index} ->
        {key, :atomics.get(counters, index) / System.convert_time_unit(1, :millisecond, :native)}
      end)

    Map.merge(timings, %{
      "db.query.count" => :atomics.get(counters, 2),
      "db.query.coverage" => "current_process_and_preloads"
    })
  end

  defp live_attributes(%{socket: %{view: view, transport_pid: transport}}) do
    case view_name(view) do
      nil ->
        :error

      name ->
        {:ok,
         %{"view" => name, "lifecycle" => if(is_pid(transport), do: "connected", else: "static")}}
    end
  end

  defp live_attributes(_), do: :error
  defp view_name(ResidencyScheduleWeb.ScheduleLive.Index), do: "schedule"
  defp view_name(ResidencyScheduleWeb.CalendarLive.Index), do: "calendar"
  defp view_name(_), do: nil
end
