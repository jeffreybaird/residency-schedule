defmodule ResidencyScheduleWeb.TelemetryHooks do
  @moduledoc """
  LiveView `on_mount` hook that stamps user-journey identifiers onto
  LiveView telemetry.

  The HTTP request that serves (and later upgrades) a LiveView passes
  through `ResidencyScheduleWeb.Plugs.TelemetryContext`, which guarantees
  the session carries a `:telemetry_session_id`. This hook re-stamps those
  identifiers inside the LiveView process, where the plug's stamps don't
  reach:

    * at mount — LiveView wraps `on_mount` hooks inside the
      `[:phoenix, :live_view, :mount]` telemetry span, so the stamp lands on
      the mount span and the process's Logger metadata
    * on every `handle_event`/`handle_params` — via `attach_hook/4`, which
      runs inside the per-event spans created by `OpentelemetryPhoenix`

  Attach before the `UserAuth` hooks in each `live_session` so mounts that
  get halted by auth redirects are still stamped.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [attach_hook: 4]

  alias ResidencySchedule.Observability

  @doc """
  `on_mount` hook. Stamps the mount span and Logger metadata with the
  session's journey identifiers, assigns `:telemetry_session_id`, and
  attaches hooks that re-stamp every subsequent `handle_event` and (on
  router-mounted LiveViews) `handle_params` span. Always continues the
  mount.

  Exempt from doctest — operates on a LiveView socket and session.
  """
  def on_mount(:telemetry_context, _params, session, socket) do
    session_id = session["telemetry_session_id"]
    user_id = session["user_id"]

    Observability.stamp_journey(session_id, user_id)

    {:cont,
     socket
     |> assign(:telemetry_session_id, session_id)
     |> attach_event_hook(session_id, user_id)
     |> attach_params_hook(session_id, user_id)}
  end

  defp attach_event_hook(socket, session_id, user_id) do
    attach_hook(socket, :telemetry_context_event, :handle_event, fn _event, _params, socket ->
      Observability.stamp_journey(session_id, user_id)
      {:cont, socket}
    end)
  end

  # :handle_params hooks may only be attached to LiveViews mounted at the
  # router (Phoenix raises otherwise) — mirrored here by the :router check.
  # LiveViews without a router never receive handle_params anyway.
  defp attach_params_hook(%{router: nil} = socket, _session_id, _user_id), do: socket

  defp attach_params_hook(socket, session_id, user_id) do
    attach_hook(socket, :telemetry_context_params, :handle_params, fn _params, _uri, socket ->
      Observability.stamp_journey(session_id, user_id)
      {:cont, socket}
    end)
  end
end
