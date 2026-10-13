defmodule ResidencyScheduleWeb.LiveSerializer do
  @moduledoc """
  Phoenix V2 protocol delegation with bounded, pre-compression encode diagnostics.

  The encoder runs exactly once. Incoming messages and fastlane broadcasts retain
  Phoenix's implementation unchanged. No topic, payload or reference is exported.
  """
  @behaviour Phoenix.Socket.Serializer

  alias Phoenix.Socket.{Message, Reply}
  alias Phoenix.Socket.V2.JSONSerializer
  alias ResidencySchedule.Observability.Tracing

  @impl true
  def encode!(message),
    do: Tracing.encode(kind(message), fn -> JSONSerializer.encode!(message) end)

  @impl true
  defdelegate decode!(message, options), to: JSONSerializer

  @impl true
  defdelegate fastlane!(message), to: JSONSerializer

  defp kind(%Message{topic: "lv:" <> _, event: "diff", payload: payload}) when is_map(payload),
    do: :diff

  defp kind(%Reply{topic: "lv:" <> _, payload: %{rendered: rendered}}) when is_map(rendered),
    do: :join

  defp kind(%Reply{topic: "lv:" <> _, payload: %{diff: diff}}) when is_map(diff), do: :diff
  defp kind(%Reply{topic: "lv:" <> _}), do: :reply
  defp kind(_), do: nil
end
