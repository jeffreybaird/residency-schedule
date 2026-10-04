defmodule ResidencySchedule.Observability do
  @moduledoc """
  Opt-in OTLP export of aggregate metrics and sanitized HTTP operation summaries.

  Request bodies, paths, headers, query strings, database statements, and ordinary
  application logs never enter this pipeline. Delivery is bounded and best effort.
  """
  use Supervisor
  import Telemetry.Metrics

  alias OtlpShipper.{Buffer, Config, Encoder, MetricsReporter, TraceExporter, Transport}

  @methods ~w(GET HEAD POST PUT DELETE CONNECT OPTIONS TRACE PATCH)

  @doc """
  Returns the configured optional supervision child.

      iex> ResidencySchedule.Observability.children()
      []
  """
  def children do
    config = Application.get_env(:residency_schedule, :observability, [])
    if config[:enabled] == true, do: [{__MODULE__, config}], else: []
  end

  @doc """
  Starts the export supervision tree with explicit collector options.

      iex> opts = [endpoint: "http://localhost:4318", token: "example", environment: "test"]
      iex> {:ok, pid} = ResidencySchedule.Observability.start_link(opts)
      iex> Supervisor.stop(pid)
      :ok
  """
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Requests asynchronous export of pending signals; this does not confirm delivery.

      iex> ResidencySchedule.Observability.flush()
      :ok
  """
  def flush do
    if Process.whereis(__MODULE__) do
      __MODULE__.LogBuffer |> Buffer.handle() |> Buffer.flush()
      MetricsReporter.flush(__MODULE__.Metrics)
      :otel_tracer_provider.force_flush(__MODULE__.Traces)
    end

    :ok
  end

  @doc """
  Selects bounded HTTP attributes from endpoint metadata.

      iex> ResidencySchedule.Observability.request_attributes(%{conn: %{method: "GET", status: 200}})
      %{"http.request.method" => "GET", "http.response.status_code" => 200}
  """
  def request_attributes(%{conn: %{method: method, status: status}}) do
    %{"http.request.method" => if(method in @methods, do: method, else: "_OTHER")}
    |> put_status(status)
  end

  def request_attributes(_), do: %{"http.request.method" => "_OTHER"}

  @doc """
  Defines tagless request, database, and VM aggregates.

      iex> ResidencySchedule.Observability.metrics() |> Enum.all?(&(&1.tags == []))
      true
  """
  def metrics do
    [counter("phoenix.endpoint.stop.count", measurement: :duration)] ++
      Enum.map(
        ["phoenix.endpoint.stop.duration"] ++
          Enum.map(~w(total_time query_time queue_time decode_time idle_time), fn timing ->
            "residency_schedule.repo.query.#{timing}"
          end),
        &distribution(&1,
          unit: {:native, :millisecond},
          reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000, 5000]]
        )
      ) ++
      [last_value("vm.memory.total", unit: :byte)] ++
      Enum.map(~w(total cpu io), &last_value("vm.total_run_queue_lengths.#{&1}"))
  end

  @impl true
  def init(opts) do
    # SDK 1.7 stores span limits globally, even for a named provider. Initialize
    # its version-pinned limits API without starting a global provider or exporter.
    :otel_span_limits.set(%{
      attribute_count_limit: 2,
      attribute_value_length_limit: 64,
      event_count_limit: 0,
      link_count_limit: 0,
      attribute_per_event_limit: 0,
      attribute_per_link_limit: 0
    })

    shared = [
      service_name: "residency-schedule",
      resource: %{"deployment.environment.name" => Keyword.fetch!(opts, :environment)},
      headers: [{"authorization", "Bearer " <> Keyword.fetch!(opts, :token)}],
      flush_ms: Keyword.get(opts, :flush_ms, 5_000),
      timeout: 5_000,
      max_retries: 1,
      max_queue: 2048,
      max_batch: 256
    ]

    base = opts |> Keyword.fetch!(:endpoint) |> String.trim_trailing("/")
    {:ok, log_config} = Config.new(:logs, Keyword.put(shared, :endpoint, base <> "/v1/logs"))

    children = [
      {Finch, name: __MODULE__.LogFinch, pools: %{default: [size: 1, count: 1]}},
      {Buffer, name: __MODULE__.LogBuffer, config: log_config, export: log_export(log_config)},
      {MetricsReporter,
       shared ++
         [
           endpoint: base <> "/v1/metrics",
           metrics: metrics(),
           name: __MODULE__.Metrics,
           finch_name: __MODULE__.MetricsFinch,
           max_series: 16
         ]},
      TraceExporter.pool_child_spec(__MODULE__.TraceFinch),
      %{
        id: :otel_span_sup,
        type: :supervisor,
        start:
          {:otel_span_sup, :start_link,
           [
             %{
               sweeper: %{
                 interval: 1_000,
                 strategy: :drop,
                 span_ttl: 60_000,
                 storage_size: 10_000
               }
             }
           ]}
      },
      trace_provider(base, shared),
      __MODULE__.RequestHandler
    ]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  defp put_status(attrs, status) when is_integer(status) and status in 100..599,
    do: Map.put(attrs, "http.response.status_code", status)

  defp put_status(attrs, _), do: attrs

  defp log_export(config) do
    fn records ->
      with {:ok, body} <- Encoder.encode(:logs, records, config.resource) do
        Transport.export(config, __MODULE__.LogFinch, body, length(records))
      end
    end
  end

  defp trace_provider(base, shared) do
    resource =
      shared[:resource]
      |> Map.put("service.name", "residency-schedule")
      |> :otel_resource.create()

    batch = %{
      name: __MODULE__.Traces,
      resource: resource,
      exporter:
        {TraceExporter,
         [pool: __MODULE__.TraceFinch, endpoint: base <> "/v1/traces"] ++
           Keyword.take(shared, [:headers, :timeout, :max_retries, :max_batch])},
      scheduled_delay_ms: shared[:flush_ms],
      exporting_timeout_ms: 7_000,
      max_queue_size: 2048
    }

    provider = %{
      id_generator: :otel_id_generator,
      sampler: {OtlpShipper.TraceSampler, :always_on},
      processors: [{:otel_batch_processor, batch}],
      deny_list: []
    }

    %{
      id: __MODULE__.Traces,
      type: :supervisor,
      start: {:otel_tracer_server_sup, :start_link, [__MODULE__.Traces, resource, provider]}
    }
  end
end
