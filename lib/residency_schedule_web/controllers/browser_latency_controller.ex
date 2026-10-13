defmodule ResidencyScheduleWeb.BrowserLatencyController do
  @moduledoc "Accepts bounded browser latency samples from authenticated sessions."
  use ResidencyScheduleWeb, :controller

  @doc """
  Responds to a browser latency sample.

      iex> sample = %{"view" => "calendar", "operation" => "event", "duration_ms" => 100}
      iex> conn = ResidencyScheduleWeb.BrowserLatencyController.create(Plug.Test.conn(:post, "/observability/browser-latency"), sample)
      iex> conn.status
      204
  """
  def create(conn, params) do
    case ResidencySchedule.Observability.record_browser_latency(params) do
      :ok -> send_resp(conn, 204, "")
      {:error, :invalid_sample} -> send_resp(conn, 422, "")
    end
  end
end
