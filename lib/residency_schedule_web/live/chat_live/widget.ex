defmodule ResidencyScheduleWeb.ChatLive.Widget do
  @moduledoc """
  The chat assistant, rendered by the `:site` live layout as a launcher button
  in the bottom-right corner that opens a floating panel.

  The conversation itself lives in `Chat.Session`, one process per user on
  the server. The widget subscribes to it, renders whatever it broadcasts,
  and forwards the user's messages and approvals to it. That is what lets a
  reload, a second tab, or a closed panel mid-reply pick up where the chat
  was; only whether the panel is open belongs to this page.

  The layout renders it sticky, so live navigation keeps the widget itself.
  Chat being off renders nothing.
  """
  use ResidencyScheduleWeb, :live_view

  on_mount {ResidencyScheduleWeb.UserAuth, :ensure_authenticated}

  alias ResidencySchedule.Assistant.Chat
  alias ResidencySchedule.Assistant.Chat.{Markdown, Session, ToolResult}

  @impl true
  def mount(_params, _session, socket) do
    user = socket.assigns.current_user
    enabled = Chat.enabled?()

    if enabled and connected?(socket), do: Session.subscribe(user)

    {:ok,
     socket
     |> assign(enabled: enabled, open: false)
     |> assign_session(if enabled, do: Session.state(user), else: idle_view())}
  end

  # ── Events ─────────────────────────────────────────────────────────────────

  @impl true
  def handle_event("open", _params, socket), do: {:noreply, assign(socket, open: true)}
  def handle_event("close", _params, socket), do: {:noreply, assign(socket, open: false)}

  def handle_event("send", %{"message" => text}, socket) do
    if socket.assigns.enabled, do: Session.send(socket.assigns.current_user, text)
    {:noreply, socket}
  end

  def handle_event("approve", _params, socket) do
    Session.approve(socket.assigns.current_user)
    {:noreply, socket}
  end

  def handle_event("deny", _params, socket) do
    Session.deny(socket.assigns.current_user)
    {:noreply, socket}
  end

  def handle_event("reset", _params, socket) do
    Session.reset(socket.assigns.current_user)
    {:noreply, socket}
  end

  # ── Session broadcasts ─────────────────────────────────────────────────────

  @impl true
  def handle_info({:chat_session, view}, socket), do: {:noreply, assign_session(socket, view)}

  defp assign_session(socket, view) do
    assign(socket,
      entries: view.entries,
      busy: view.busy,
      pending: view.pending,
      remaining: view.remaining,
      error: view.error && describe_error(view.error)
    )
  end

  defp idle_view, do: %{entries: [], busy: false, pending: [], remaining: 0, error: nil}

  # ── Presentation ───────────────────────────────────────────────────────────

  defp describe_error(:limit_reached),
    do: "You have used today's #{Chat.daily_limit()} messages. Try again tomorrow."

  defp describe_error(:crashed),
    do: "The assistant stopped unexpectedly. The error has been logged."

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
        class="fixed inset-x-2 bottom-2 z-40 flex h-[70vh] flex-col rounded-2xl border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 shadow-2xl sm:inset-x-auto sm:bottom-4 sm:right-4 sm:h-[32rem] sm:max-h-[calc(100vh-2rem)] sm:w-96"
      >
        <div class="flex items-center justify-between gap-2 border-b border-gray-200 dark:border-gray-700 px-4 py-2">
          <h2 class="text-sm font-semibold text-gray-800 dark:text-gray-100">Assistant</h2>
          <div class="flex items-center gap-2 text-xs text-gray-500 dark:text-gray-300">
            <span id="chat-remaining">{@remaining} messages left today</span>
            <button
              :if={@entries != []}
              type="button"
              phx-click="reset"
              disabled={@busy}
              class="rounded-full bg-gray-100 dark:bg-gray-800 px-2 py-0.5 font-medium text-gray-700 dark:text-gray-200 hover:bg-gray-200 dark:hover:bg-gray-700 disabled:opacity-50"
            >
              New chat
            </button>
            <button
              id="chat-close"
              type="button"
              phx-click="close"
              aria-label="Close the assistant"
              class="rounded-md p-1 text-gray-500 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-800 hover:text-gray-800 dark:hover:text-gray-100"
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
          <p :if={@entries == []} class="text-sm text-gray-500 dark:text-gray-300">
            Ask about who is on a service, a resident's schedule, shared shifts, or coverage.
          </p>
          <.entry :for={entry <- @entries} entry={entry} />
          <p :if={@busy} id="chat-thinking" class="text-xs text-gray-400 dark:text-gray-400">
            Working…
          </p>
        </div>

        <div
          :if={@pending != []}
          id="chat-approval"
          class="space-y-2 border-t border-amber-200 dark:border-amber-800 bg-amber-50 dark:bg-amber-950 px-4 py-3"
        >
          <p class="text-sm font-semibold text-amber-900 dark:text-amber-300">
            The assistant wants to make a change. Run it?
          </p>
          <div
            :for={call <- @pending}
            class="rounded-lg border border-amber-200 dark:border-amber-800 bg-white dark:bg-gray-900 p-2"
          >
            <p class="text-sm font-medium text-gray-800 dark:text-gray-100">
              {tool_label(call.name)}
            </p>
            <pre class="mt-1 whitespace-pre-wrap text-xs text-gray-600 dark:text-gray-300">{format_args(call.args)}</pre>
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
              class="rounded-md bg-gray-100 dark:bg-gray-800 px-3 py-1 text-sm font-medium text-gray-700 dark:text-gray-200 hover:bg-gray-200 dark:hover:bg-gray-700 disabled:opacity-50"
            >
              Deny
            </button>
          </div>
        </div>

        <p
          :if={@error}
          id="chat-error"
          class="mx-4 mb-2 rounded-lg border border-red-200 dark:border-red-800 bg-red-50 dark:bg-red-950 px-3 py-2 text-sm text-red-700 dark:text-red-300"
        >
          {@error}
        </p>

        <form
          id="chat-form"
          phx-submit="send"
          class="flex gap-2 border-t border-gray-200 dark:border-gray-700 px-3 py-2"
        >
          <input
            type="text"
            name="message"
            autocomplete="off"
            placeholder="Who is on onc tomorrow?"
            disabled={@busy or @pending != []}
            phx-mounted={JS.focus()}
            class="min-w-0 flex-1 rounded-md border border-gray-300 dark:border-gray-600 px-3 py-2 text-sm focus:border-blue-500 focus:outline-none disabled:bg-gray-50 dark:disabled:bg-gray-950"
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
      <p
        phx-no-format
        class="max-w-[85%] rounded-2xl bg-blue-600 px-3 py-2 text-sm text-white whitespace-pre-wrap"
      >{@entry.text}</p>
    </div>
    """
  end

  defp entry(%{entry: %{kind: :assistant}} = assigns) do
    ~H"""
    <div id={"entry-#{@entry.id}"} data-kind="assistant" class="flex justify-start">
      <div class="chat-markdown max-w-[85%] rounded-2xl bg-gray-100 px-3 py-2 dark:bg-gray-800 text-sm text-gray-800 dark:text-gray-100">
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
      <p class="text-xs text-gray-500 dark:text-gray-300 px-2">
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
