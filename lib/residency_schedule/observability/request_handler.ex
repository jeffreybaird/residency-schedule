defmodule ResidencySchedule.Observability.RequestHandler do
  @moduledoc false
  use GenServer

  alias OtlpShipper.{Buffer, Value}
  alias ResidencySchedule.Observability

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)

    state = %{
      buffer: Buffer.handle(Observability.LogBuffer),
      tracer:
        :otel_tracer_provider.get_tracer(
          Observability.Traces,
          "residency-schedule",
          "0.1.0",
          :undefined
        )
    }

    :telemetry.detach(__MODULE__)

    :ok =
      :telemetry.attach(
        __MODULE__,
        [:phoenix, :endpoint, :stop],
        &__MODULE__.handle_event/4,
        state
      )

    {:ok, state}
  end

  @doc """
  Records a sanitized completed request when a valid duration is available.

      iex> ResidencySchedule.Observability.RequestHandler.handle_event([], %{}, %{}, %{})
      :ok
  """
  def handle_event(_, %{duration: duration}, metadata, state)
      when is_integer(duration) and duration >= 0 do
    attributes = Observability.request_attributes(metadata)
    ended = :opentelemetry.timestamp()

    span =
      :otel_tracer.start_span(:otel_ctx.new(), state.tracer, "HTTP request", %{
        kind: :server,
        start_time: ended - duration,
        attributes: attributes
      })

    :otel_span.end_span(span, ended)

    Buffer.enqueue(state.buffer, %{
      time_unix_nano: :opentelemetry.timestamp_to_nano(ended),
      severity_number: 9,
      severity_text: "info",
      body: Value.encode("HTTP request completed"),
      attributes: Value.attributes(attributes),
      trace_id: <<:otel_span.trace_id(span)::128>>,
      span_id: <<:otel_span.span_id(span)::64>>,
      flags: 1
    })

    :ok
  end

  def handle_event(_, _, _, _), do: :ok

  @impl true
  def terminate(_, _) do
    :telemetry.detach(__MODULE__)
    :ok
  end
end
