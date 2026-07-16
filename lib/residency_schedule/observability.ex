defmodule ResidencySchedule.Observability do
  @moduledoc """
  Attaches OpenTelemetry instrumentation to the app's `:telemetry` events.

  Called once from `ResidencySchedule.Application.start/2`, before the
  supervision tree boots, so even the earliest requests are traced. Whether
  the resulting spans leave the node is controlled entirely by config:
  `traces_exporter: :none` everywhere except prod, where OTLP exports to a
  local Grafana Alloy agent (see `config/runtime.exs` and DEPLOY.md).
  """

  require Logger
  require OpenTelemetry.Tracer, as: Tracer

  @doc """
  Attaches all OpenTelemetry telemetry handlers — Bandit (HTTP server
  spans), Phoenix router + LiveView spans, Ecto query spans — and the
  Logger filter that stamps `otel_trace_id`/`otel_span_id` metadata onto
  every log line for trace ↔ log correlation.

  Safe to call more than once: handlers that are already attached are left
  in place.

      iex> ResidencySchedule.Observability.setup()
      :ok

  """
  def setup do
    OpentelemetryBandit.setup()
    OpentelemetryPhoenix.setup(adapter: :bandit, liveview: true)
    OpentelemetryEcto.setup([:residency_schedule, :repo], db_statement: :enabled)
    OpentelemetryLoggerMetadata.setup()
    :ok
  end

  @doc """
  Stamps user-journey identifiers onto the currently active OpenTelemetry
  span (`session.id` / `enduser.id`, per OTel semantic conventions) and onto
  the calling process's Logger metadata (`session_id` / `user_id`).

  Searching Tempo for `enduser.id` or `session.id` then lists every trace a
  person produced, in order — their journey through the app. A `nil`
  `user_id` (anonymous visitor) stamps only the session identifiers; a `nil`
  `session_id` is skipped entirely. Called outside any active span, the span
  stamp is a no-op while the Logger metadata is still set.

      iex> ResidencySchedule.Observability.stamp_journey("6ba7b814-9dad-11d1-80b4-00c04fd430c8", 42)
      :ok

  """
  def stamp_journey(session_id, user_id) do
    session_id
    |> journey_span_attributes(user_id)
    |> Tracer.set_attributes()

    Logger.metadata(session_id: session_id, user_id: user_id)
    :ok
  end

  defp journey_span_attributes(session_id, user_id) do
    %{"session.id" => session_id, "enduser.id" => user_id && to_string(user_id)}
    |> reject_nil_attributes()
  end

  defp reject_nil_attributes(attributes) do
    Map.reject(attributes, fn {_key, value} -> is_nil(value) end)
  end
end
