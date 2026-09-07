defmodule ResidencySchedule.Assistant.Chat.Provider do
  @moduledoc """
  The seam between the chat loop and a model provider. Adapters implement
  `stream/3`; the loop calls `stream/2` here, which resolves the active
  adapter from `config :residency_schedule, :chat`.

  Events are emitted through the callback as the model produces them:

    * `{:text_delta, string}` — a fragment of visible text
    * `{:tool_call, ToolCall.t()}` — a complete call the loop must run
    * `{:done, meta}` — the turn ended; `meta` carries `stop` and `usage`

  The return value is the full assistant `Message` (with the adapter's raw
  payload for replay) plus the same `meta`.
  """

  alias ResidencySchedule.Assistant.Chat.{Message, Request, ToolCall}

  @type stop :: :end_turn | :tool_use | :max_tokens | :refusal | :unknown
  @type meta :: %{stop: stop, usage: map, model: String.t() | nil}
  @type event :: {:text_delta, String.t()} | {:tool_call, ToolCall.t()} | {:done, meta}
  @type on_event :: (event -> any)

  @callback stream(Request.t(), config :: keyword, on_event) ::
              {:ok, Message.t(), meta} | {:error, term}

  @doc """
  The active adapter module and its config.

      iex> {:ok, {module, config}} = ResidencySchedule.Assistant.Chat.Provider.current()
      iex> {module, Keyword.fetch!(config, :model)}
      {ResidencySchedule.Assistant.Chat.Providers.Fake, "fake"}
  """
  def current do
    config = Application.get_env(:residency_schedule, :chat, [])

    case Keyword.fetch(config, :provider) do
      {:ok, module} when is_atom(module) -> {:ok, {module, config}}
      _ -> {:error, :chat_not_configured}
    end
  end

  @doc """
  Streams one turn through the active adapter.

      iex> alias ResidencySchedule.Assistant.Chat.{Message, Request}
      iex> request = Request.new(messages: [Message.user("Hi")])
      iex> {:ok, reply, meta} = ResidencySchedule.Assistant.Chat.Provider.stream(request, fn _event -> :ok end)
      iex> {Message.text(reply), meta.stop}
      {"fake: Hi", :end_turn}
  """
  def stream(%Request{} = request, on_event) when is_function(on_event, 1) do
    with {:ok, {module, config}} <- current() do
      module.stream(request, config, on_event)
    end
  end
end
