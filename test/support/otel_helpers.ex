defmodule ResidencySchedule.OtelHelpers do
  @moduledoc """
  Test helpers for capturing OpenTelemetry spans in-process.

  `setup :capture_spans` points the globally-running simple span processor
  (configured in `config/test.exs`) at the test pid, so every finished span
  arrives as a `{:span, span_record}` message. Use only in `async: false`
  test modules — the exporter is global. The SDK app is deliberately never
  restarted: tracers are cached in `persistent_term` and keep referencing
  the pre-restart processor pipeline, silently dropping all spans.
  """

  import ExUnit.Assertions

  require Record

  @span_fields Record.extract(:span, from_lib: "opentelemetry/include/otel_span.hrl")
  Record.defrecord(:otel_span, :span, @span_fields)

  @doc """
  ExUnit setup callback: routes all finished spans to the test process.
  No reset on exit is needed — sends to a finished test's pid are no-ops,
  and the next capturing test swaps the exporter to its own pid.
  """
  def capture_spans(_context) do
    :otel_simple_processor.set_exporter(:otel_exporter_pid, self())
    :ok
  end

  @doc """
  Awaits the first captured span with the given name and returns it.
  Flunks after `timeout` ms.
  """
  def await_span(name, timeout \\ 2_000) do
    receive do
      {:span, span} ->
        if span_name(span) == name, do: span, else: await_span(name, timeout)
    after
      timeout -> flunk("no span named #{inspect(name)} was exported")
    end
  end

  @doc """
  Returns the span's name as recorded by the SDK.
  """
  def span_name(span), do: otel_span(span, :name)

  @doc """
  Returns the span's attributes as a plain map.
  """
  def span_attributes(span) do
    span
    |> otel_span(:attributes)
    |> :otel_attributes.map()
  end
end
