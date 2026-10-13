defmodule ResidencySchedule.Observability.RequestHandler do
  @moduledoc false
  use GenServer

  alias OtlpShipper.{Buffer, Value}
  alias ResidencySchedule.Observability
  alias ResidencySchedule.Observability.Tracing

  @doc false
  def start_link(_opts), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    Process.flag(:trap_exit, true)

    state = %{buffer: Buffer.handle(Observability.LogBuffer)}

    :telemetry.detach(__MODULE__)
    :telemetry.detach(Tracing)

    :ok = :telemetry.attach_many(Tracing, Tracing.events(), &Tracing.handle_event/4, nil)

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

    Tracing.set_http_attributes(metadata)

    if span = Tracing.current_span() do
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
    end

    :ok
  end

  def handle_event(_, _, _, _), do: :ok

  @impl true
  def terminate(_, _) do
    :telemetry.detach(__MODULE__)
    :telemetry.detach(Tracing)
    :ok
  end
end
