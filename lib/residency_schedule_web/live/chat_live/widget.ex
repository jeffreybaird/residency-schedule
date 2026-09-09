defmodule ResidencyScheduleWeb.ChatLive.Widget do
  @moduledoc """
  The chat assistant, rendered by the `:site` live layout as a launcher button
  in the bottom-right corner that opens a floating panel. Each turn runs in a
  task so the socket keeps rendering text as it streams; tool calls that
  change data pause for the user's approval before they run.

  The layout renders it sticky, so live navigation between signed-in pages
  keeps the widget and its conversation; a full page load starts a fresh one.
  Chat being off renders nothing.
  """
  use ResidencyScheduleWeb, :live_view

  on_mount {ResidencyScheduleWeb.UserAuth, :ensure_authenticated}

  require Logger

  alias ResidencySchedule.Assistant.Chat
  alias ResidencySchedule.Assistant.Chat.{Conversation, Markdown, Quota, ToolCall, ToolResult}
  alias ResidencySchedule.Assistant.LocalDate
  alias ResidencyScheduleWeb.MCP.Toolbox

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    today = LocalDate.today()

    {:ok,
     assign(socket,
       enabled: Chat.enabled?(),
       open: false,
       conversation: Conversation.new(toolbox: Toolbox, user: user),
       entries: [],
       next_id: 1,
       busy: false,
       pending: [],
       remaining: remaining(user, today),
       today: today,
       error: nil
     )}
  end

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("open", _params, socket), do: {:noreply, assign(socket, open: true)}
  def handle_event("close", _params, socket), do: {:noreply, assign(socket, open: false)}

  def handle_event("send", %{"message" => text}, socket) do
    text = String.trim(text)

    if text == "" or not accepting?(socket),
      do: {:noreply, socket},
      else: {:noreply, start_turn(socket, text)}
  end

  def handle_event("approve", _params, socket) do
    {:noreply, decide(socket, &Conversation.approve/2)}
  end

  def handle_event("deny", _params, socket) do
    {:noreply, decide(socket, &Conversation.deny/2)}
  end

  def handle_event("reset", _params, socket) do
    {:noreply,
     assign(socket,
       conversation: Conversation.new(toolbox: Toolbox, user: socket.assigns.current_user),
       entries: [],
       pending: [],
       error: nil
     )}
  end

  # ── Streaming events from the turn task ────────────────────────────────────

  @impl true
  def handle_info({:chat_event, {:text_delta, text}}, socket) do
    {:noreply, append_text(socket, text)}
  end

  def handle_info({:chat_event, {:tool_call, %ToolCall{} = call}}, socket) do
    {:noreply, add_entry(socket, %{kind: :tool, call: call, result: nil})}
  end

  def handle_info(
        {:chat_event, {:tool_result, %ToolCall{} = call, %ToolResult{} = result}},
        socket
      ) do
    {:noreply, update_entries(socket, &finish_tool(&1, call.id, result))}
  end

  def handle_info({:chat_event, {:approval_required, calls}}, socket) do
    {:noreply, assign(socket, pending: calls)}
  end

  def handle_info({:chat_event, _other}, socket), do: {:noreply, socket}

  @impl true
  def handle_async(:turn, {:ok, {:ok, conversation}}, socket) do
    {:noreply, finish_turn(socket, conversation, nil)}
  end

  def handle_async(:turn, {:ok, {:error, reason, conversation}}, socket) do
    {:noreply, finish_turn(socket, conversation, describe_error(reason))}
  end

  def handle_async(:turn, {:exit, reason}, socket) do
    Logger.error("chat turn crashed: " <> Exception.format_exit(reason))

    {:noreply,
     finish_turn(
       socket,
       socket.assigns.conversation,
       "The assistant stopped unexpectedly. The error has been logged."
     )}
  end

  # ── Turn lifecycle ─────────────────────────────────────────────────────────

  defp accepting?(%{assigns: assigns}) do
    assigns.enabled and not assigns.busy and assigns.pending == []
  end

  defp start_turn(socket, text) do
    case Quota.consume(socket.assigns.current_user, socket.assigns.today) do
      {:ok, remaining} ->
        socket
        |> assign(remaining: remaining, error: nil)
        |> add_entry(%{kind: :user, text: text})
        |> run_turn(&Conversation.send(&1, text, &2))

      {:error, :limit_reached} ->
        assign(socket, remaining: 0, error: limit_message())
    end
  end

  defp decide(socket, decision) do
    if socket.assigns.pending == [] or socket.assigns.busy do
      socket
    else
      socket
      |> assign(pending: [], error: nil)
      |> run_turn(decision)
    end
  end

  defp run_turn(socket, turn) do
    conversation = socket.assigns.conversation
    on_event = event_forwarder(self())

    socket
    |> assign(busy: true)
    |> start_async(:turn, fn -> turn.(conversation, on_event) end)
  end

  defp event_forwarder(pid), do: fn event -> send(pid, {:chat_event, event}) end

  defp finish_turn(socket, conversation, error) do
    socket
    |> assign(
      conversation: conversation,
      busy: false,
      pending: conversation.pending,
      error: error
    )
    |> update_entries(&reject_empty_text/1)
  end

  # ── Entries ────────────────────────────────────────────────────────────────

  defp add_entry(socket, entry) do
    id = socket.assigns.next_id

    socket
    |> update(:entries, &(&1 ++ [Map.put(entry, :id, id)]))
    |> assign(next_id: id + 1)
  end

  defp update_entries(socket, fun), do: update(socket, :entries, fun)

  defp append_text(socket, text) do
    case List.last(socket.assigns.entries) do
      %{kind: :assistant} ->
        update_entries(
          socket,
          &List.update_at(&1, -1, fn entry -> %{entry | text: entry.text <> text} end)
        )

      _other ->
        add_entry(socket, %{kind: :assistant, text: text})
    end
  end

  defp finish_tool(entries, call_id, result) do
    Enum.map(entries, fn
      %{kind: :tool, call: %ToolCall{id: ^call_id}} = entry -> %{entry | result: result}
      entry -> entry
    end)
  end

  defp reject_empty_text(entries) do
    Enum.reject(entries, &match?(%{kind: :assistant, text: ""}, &1))
  end

  # ── Presentation ───────────────────────────────────────────────────────────

  defp remaining(%{id: nil}, _today), do: 0
  defp remaining(user, today), do: Quota.remaining(user, today)

  defp limit_message,
    do: "You have used today's #{Chat.daily_limit()} messages. Try again tomorrow."

  defp describe_error(:max_tool_rounds),
    do: "The assistant used too many tools for one message. Try a narrower question."

  defp describe_error(:missing_api_key), do: "The assistant is not configured on this server."
  defp describe_error(:chat_not_configured), do: "The assistant is not configured on this server."
  defp describe_error({:transport, _}), do: "Could not reach the model service. Try again."

  defp describe_error({:api_error, %{message: message}}),
    do: "The model service returned an error: #{message}"

  defp describe_error(other), do: "Something went wrong: #{inspect(other)}"

  @doc """
  Turns a tool name into a readable label.

      iex> ResidencyScheduleWeb.ChatLive.Widget.tool_label("request_coverage")
      "Request coverage"
  """
  def tool_label(name) do
    name
    |> String.replace("_", " ")
    |> String.capitalize()
  end

  @doc """
  Pretty-prints tool arguments for the approval card.

      iex> ResidencyScheduleWeb.ChatLive.Widget.format_args(%{"covering" => "Nora"})
      "covering: Nora"
  """
  def format_args(args) when map_size(args) == 0, do: "no arguments"

  def format_args(args) do
    Enum.map_join(args, "\n", fn {key, value} -> "#{key}: #{format_value(value)}" end)
  end

  defp format_value(value) when is_binary(value), do: value
  defp format_value(value), do: Jason.encode!(value)

  # ── Template ───────────────────────────────────────────────────────────────

  @impl true
  def render(assigns) do
    ~H"""
    <div :if={@enabled} id="chat-widget-root">
      <button
        :if={!@open}
        id="chat-launcher"
        type="button"
        phx-click="open"
        aria-label="Open the assistant"
        title="Assistant"
        class="fixed bottom-4 right-4 z-40 flex h-14 w-14 items-center justify-center rounded-full bg-blue-600 text-white shadow-lg hover:bg-blue-700 focus:outline-none focus:ring-2 focus:ring-blue-400 focus:ring-offset-2"
      >
        <.icon name="hero-chat-bubble-left-right" class="size-7" />
      </button>

      <section
        :if={@open}
        id="chat-panel"
        role="dialog"
        aria-label="Assistant"
        class="fixed inset-x-2 bottom-2 z-40 flex h-[70vh] flex-col rounded-2xl border border-gray-200 bg-white shadow-2xl sm:inset-x-auto sm:bottom-4 sm:right-4 sm:h-[32rem] sm:max-h-[calc(100vh-2rem)] sm:w-96"
      >
        <div class="flex items-center justify-between gap-2 border-b border-gray-200 px-4 py-2">
          <h2 class="text-sm font-semibold text-gray-800">Assistant</h2>
          <div class="flex items-center gap-2 text-xs text-gray-500">
            <span id="chat-remaining">{@remaining} messages left today</span>
            <button
              :if={@entries != []}
              type="button"
              phx-click="reset"
              disabled={@busy}
              class="rounded-full bg-gray-100 px-2 py-0.5 font-medium text-gray-700 hover:bg-gray-200 disabled:opacity-50"
            >
              New chat
            </button>
            <button
              id="chat-close"
              type="button"
              phx-click="close"
              aria-label="Close the assistant"
              class="rounded-md p-1 text-gray-500 hover:bg-gray-100 hover:text-gray-800"
            >
              <.icon name="hero-x-mark" class="size-4" />
            </button>
          </div>
        </div>

        <div
          id="chat-log"
          phx-hook="ChatScroll"
          class="min-h-0 flex-1 space-y-3 overflow-y-auto px-4 py-3"
        >
          <p :if={@entries == []} class="text-sm text-gray-500">
            Ask about who is on a service, a resident's schedule, shared shifts, or coverage.
          </p>
          <.entry :for={entry <- @entries} entry={entry} />
          <p :if={@busy} id="chat-thinking" class="text-xs text-gray-400">Working…</p>
        </div>

        <div
          :if={@pending != []}
          id="chat-approval"
          class="space-y-2 border-t border-amber-200 bg-amber-50 px-4 py-3"
        >
          <p class="text-sm font-semibold text-amber-900">
            The assistant wants to make a change. Run it?
          </p>
          <div :for={call <- @pending} class="rounded-lg border border-amber-200 bg-white p-2">
            <p class="text-sm font-medium text-gray-800">{tool_label(call.name)}</p>
            <pre class="mt-1 whitespace-pre-wrap text-xs text-gray-600">{format_args(call.args)}</pre>
          </div>
          <div class="flex gap-2">
            <button
              type="button"
              phx-click="approve"
              disabled={@busy}
              class="rounded-md bg-blue-600 px-3 py-1 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
            >
              Approve
            </button>
            <button
              type="button"
              phx-click="deny"
              disabled={@busy}
              class="rounded-md bg-gray-100 px-3 py-1 text-sm font-medium text-gray-700 hover:bg-gray-200 disabled:opacity-50"
            >
              Deny
            </button>
          </div>
        </div>

        <p
          :if={@error}
          id="chat-error"
          class="mx-4 mb-2 rounded-lg border border-red-200 bg-red-50 px-3 py-2 text-sm text-red-700"
        >
          {@error}
        </p>

        <form id="chat-form" phx-submit="send" class="flex gap-2 border-t border-gray-200 px-3 py-2">
          <input
            type="text"
            name="message"
            autocomplete="off"
            placeholder="Who is on onc tomorrow?"
            disabled={@busy or @pending != []}
            phx-mounted={JS.focus()}
            class="min-w-0 flex-1 rounded-md border border-gray-300 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none disabled:bg-gray-50"
          />
          <button
            type="submit"
            disabled={@busy or @pending != []}
            class="rounded-md bg-blue-600 px-3 py-2 text-sm font-medium text-white hover:bg-blue-700 disabled:opacity-50"
          >
            Send
          </button>
        </form>
      </section>
    </div>
    """
  end

  attr :entry, :map, required: true

  defp entry(%{entry: %{kind: :user}} = assigns) do
    ~H"""
    <div id={"entry-#{@entry.id}"} data-kind="user" class="flex justify-end">
      <p class="max-w-[85%] rounded-2xl bg-blue-600 px-3 py-2 text-sm text-white whitespace-pre-wrap">{@entry.text}</p>
    </div>
    """
  end

  defp entry(%{entry: %{kind: :assistant}} = assigns) do
    ~H"""
    <div id={"entry-#{@entry.id}"} data-kind="assistant" class="flex justify-start">
      <div class="chat-markdown max-w-[85%] rounded-2xl bg-gray-100 px-3 py-2 text-sm text-gray-800">
        {Markdown.to_html(@entry.text)}
      </div>
    </div>
    """
  end

  defp entry(%{entry: %{kind: :tool}} = assigns) do
    ~H"""
    <div
      id={"entry-#{@entry.id}"}
      data-kind="tool"
      data-status={tool_status(@entry.result)}
      class="flex justify-start"
    >
      <p class="text-xs text-gray-500 px-2">
        <span :if={is_nil(@entry.result)}>Running {tool_label(@entry.call.name)}…</span>
        <span :if={match?(%ToolResult{error?: false}, @entry.result)}>
          Used {tool_label(@entry.call.name)}
        </span>
        <span :if={match?(%ToolResult{error?: true}, @entry.result)}>
          {tool_label(@entry.call.name)} failed: {@entry.result.content}
        </span>
      </p>
    </div>
    """
  end

  defp tool_status(nil), do: "running"
  defp tool_status(%ToolResult{error?: true}), do: "error"
  defp tool_status(%ToolResult{}), do: "ok"
end
