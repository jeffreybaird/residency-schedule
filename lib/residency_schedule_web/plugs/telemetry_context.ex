defmodule ResidencyScheduleWeb.Plugs.TelemetryContext do
  @moduledoc """
  Stamps user-journey identifiers onto every browser request's telemetry.

  Ensures a stable `:telemetry_session_id` UUID lives in the signed session
  cookie (minted on first visit, so anonymous pre-login journeys are
  followable too), then stamps it — plus the logged-in user's id when
  present — onto the active OpenTelemetry span and Logger metadata via
  `ResidencySchedule.Observability.stamp_journey/2`.

  Runs in the `:browser` pipeline after `:fetch_session`. Reads `:user_id`
  straight from the session rather than `conn.assigns.current_user` so it
  works on public routes that never pass through `RequireAuth`.
  """

  import Plug.Conn

  alias ResidencySchedule.Observability

  @doc """
  Returns the options unchanged — this plug takes no options.

      iex> ResidencyScheduleWeb.Plugs.TelemetryContext.init([])
      []

  """
  def init(opts), do: opts

  @doc """
  Ensures the session carries a `:telemetry_session_id` and stamps the
  journey identifiers onto the current span and Logger metadata.

  Exempt from doctest — operates on a `Plug.Conn` with a fetched session.
  """
  def call(conn, _opts) do
    conn
    |> ensure_session_id()
    |> stamp_journey()
  end

  defp ensure_session_id(conn) do
    case get_session(conn, :telemetry_session_id) do
      nil -> put_session(conn, :telemetry_session_id, Ecto.UUID.generate())
      _session_id -> conn
    end
  end

  defp stamp_journey(conn) do
    Observability.stamp_journey(
      get_session(conn, :telemetry_session_id),
      get_session(conn, :user_id)
    )

    conn
  end
end
