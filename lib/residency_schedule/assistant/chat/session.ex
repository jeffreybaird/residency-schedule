defmodule ResidencySchedule.Assistant.Chat.Session do
  @moduledoc """
  One user's chat, held on the server so it outlives the page.

  A session is a process per user, started when first asked for and stopped
  after a stretch without activity. It owns the conversation, the transcript
  the widget renders, and the turn in progress, which runs in a task under
  the session rather than under any one LiveView: a reload or a closed tab
  mid-reply does not lose the reply. Every widget the user has open (another
  tab, a reloaded page) subscribes to the same session and renders the same
  state.

  Nothing is written to the database. A restart of the application drops
  every session, and an idle one is dropped after `:session_idle_ms` from the
  `:chat` config.

  Callers pass their `$callers` chain along with each request so the daily
  quota and tool runs inside the session can reach the caller's database
  connection under the test sandbox.
  """

  use GenServer

  require Logger

  alias ResidencySchedule.Accounts.User
  alias ResidencySchedule.Assistant.Chat.{Conversation, Quota, Transcript}
  alias ResidencySchedule.Assistant.LocalDate
  alias ResidencyScheduleWeb.MCP.Toolbox

  @registry ResidencySchedule.Assistant.Chat.SessionRegistry
  @supervisor ResidencySchedule.Assistant.Chat.SessionSupervisor
  @turns ResidencySchedule.Assistant.Chat.TurnSupervisor
  @pubsub ResidencySchedule.PubSub
  @default_idle_ms :timer.hours(2)

  @typedoc """
  What a widget renders: the transcript entries, whether a turn is running,
  tool calls waiting for approval, the last error's reason (or nil), and the
  messages left today.
  """
  @type view :: %{
          entries: [map()],
          busy: boolean(),
          pending: [ResidencySchedule.Assistant.Chat.ToolCall.t()],
          error: term() | nil,
          remaining: non_neg_integer()
        }

  # ── Supervision ───────────────────────────────────────────────────────────

  @doc """
  The processes a session needs, for the application supervisor: a registry
  of sessions by user id, a supervisor to start them under, and a task
  supervisor for turns.

      iex> ResidencySchedule.Assistant.Chat.Session.children() |> length()
      3
  """
  def children do
    [
      {Registry, keys: :unique, name: @registry},
      {DynamicSupervisor, name: @supervisor, strategy: :one_for_one},
      {Task.Supervisor, name: @turns}
    ]
  end

  @doc false
  def child_spec(%User{} = user) do
    %{id: {__MODULE__, user.id}, start: {__MODULE__, :start_link, [user]}, restart: :temporary}
  end

  @doc false
  def start_link(%User{} = user) do
    GenServer.start_link(__MODULE__, user, name: via(user))
  end

  # ── Client ────────────────────────────────────────────────────────────────

  @doc """
  The PubSub topic a user's widgets listen on.

      iex> ResidencySchedule.Assistant.Chat.Session.topic(%ResidencySchedule.Accounts.User{id: 7})
      "chat:7"
  """
  def topic(%User{id: id}), do: "chat:#{id}"

  @doc """
  Subscribes the calling process to the user's session. Every change arrives
  as `{:chat_session, view}`.

  Exempt from doctest — subscribes the calling process. See `SessionTest`.
  """
  def subscribe(%User{} = user), do: Phoenix.PubSub.subscribe(@pubsub, topic(user))

  @doc """
  The current view of the user's session, starting one if none is running.

  Exempt from doctest — starts a process and reads the quota. See `SessionTest`.
  """
  def state(%User{} = user), do: call(user, {:state, callers()})

  @doc """
  Sends a message and starts a turn. Returns `:ok`, or `{:error, reason}`
  when the text is blank, a turn is already running, or the daily limit is
  reached; the last of those is also reported in the broadcast view.

  Exempt from doctest — runs a turn in a process. See `SessionTest`.
  """
  def send(%User{} = user, text) when is_binary(text),
    do: call(user, {:send, String.trim(text), callers()})

  @doc """
  Runs the tool calls waiting for approval and resumes the turn.

  Exempt from doctest — runs a turn in a process. See `SessionTest`.
  """
  def approve(%User{} = user), do: call(user, {:decide, &Conversation.approve/2, callers()})

  @doc """
  Declines the tool calls waiting for approval and lets the model answer.

  Exempt from doctest — runs a turn in a process. See `SessionTest`.
  """
  def deny(%User{} = user), do: call(user, {:decide, &Conversation.deny/2, callers()})

  @doc """
  Starts a fresh conversation, keeping the session and its quota count.

  Exempt from doctest — changes a process. See `SessionTest`.
  """
  def reset(%User{} = user), do: call(user, :reset)

  @doc """
  The pid of the user's running session, or nil.

  Exempt from doctest — looks up a process. See `SessionTest`.
  """
  def whereis(%User{id: id}) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> pid
      [] -> nil
    end
  end

  defp call(user, request), do: user |> ensure_started() |> GenServer.call(request)

  defp ensure_started(user) do
    case DynamicSupervisor.start_child(@supervisor, {__MODULE__, user}) do
      {:ok, pid} -> pid
      {:error, {:already_started, pid}} -> pid
    end
  end

  defp via(%User{id: id}), do: {:via, Registry, {@registry, id}}

  defp callers, do: [self() | Process.get(:"$callers", [])]

  # ── Server ────────────────────────────────────────────────────────────────

  @impl true
  def init(%User{} = user) do
    {:ok, fresh(%{user: user, remaining: nil, task: nil}), idle_ms()}
  end

  @impl true
  def handle_call({:state, callers}, _from, state) do
    state = state |> adopt_callers(callers) |> ensure_remaining()
    reply(state, view(state))
  end

  def handle_call({:send, _text, _callers}, _from, %{task: task} = state) when not is_nil(task),
    do: reply(state, {:error, :busy})

  def handle_call({:send, "", _callers}, _from, state), do: reply(state, {:error, :empty})

  def handle_call({:send, text, callers}, _from, state) do
    state = adopt_callers(state, callers)

    case Quota.consume(state.user, LocalDate.today()) do
      {:ok, remaining} ->
        state
        |> Map.merge(%{remaining: remaining, error: nil})
        |> update_transcript(&Transcript.add(&1, %{kind: :user, text: text}))
        |> run_turn(&Conversation.send(&1, text, &2))
        |> reply(:ok)

      {:error, :limit_reached} ->
        state
        |> Map.merge(%{remaining: 0, error: :limit_reached})
        |> broadcast()
        |> reply({:error, :limit_reached})
    end
  end

  def handle_call({:decide, _decision, _callers}, _from, %{task: task} = state)
      when not is_nil(task),
      do: reply(state, {:error, :busy})

  def handle_call({:decide, _decision, _callers}, _from, %{conversation: %{pending: []}} = state),
    do: reply(state, {:error, :nothing_pending})

  def handle_call({:decide, decision, callers}, _from, state) do
    state
    |> adopt_callers(callers)
    |> Map.put(:error, nil)
    |> run_turn(decision)
    |> reply(:ok)
  end

  def handle_call(:reset, _from, %{task: task} = state) when not is_nil(task),
    do: reply(state, {:error, :busy})

  def handle_call(:reset, _from, state), do: state |> fresh() |> broadcast() |> reply(:ok)

  @impl true
  def handle_info({:chat_event, event}, state) do
    state |> update_transcript(&Transcript.apply_event(&1, event)) |> broadcast() |> noreply()
  end

  def handle_info({ref, result}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    state |> finish_turn(result) |> noreply()
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: %Task{ref: ref}} = state) do
    Logger.error("chat turn crashed: " <> Exception.format_exit(reason))
    state |> finish_turn({:error, :crashed, state.conversation}) |> noreply()
  end

  def handle_info(:timeout, %{task: nil} = state), do: {:stop, :normal, state}
  def handle_info(_other, state), do: noreply(state)

  # ── Turns ─────────────────────────────────────────────────────────────────

  defp run_turn(%{conversation: conversation} = state, turn) do
    session = self()
    on_event = fn event -> Kernel.send(session, {:chat_event, event}) end
    task = Task.Supervisor.async_nolink(@turns, fn -> turn.(conversation, on_event) end)

    state |> Map.put(:task, task) |> broadcast()
  end

  defp finish_turn(state, {:ok, conversation}), do: settle(state, conversation, nil)

  defp finish_turn(state, {:error, reason, conversation}),
    do: settle(state, conversation, reason)

  defp settle(state, conversation, error) do
    state
    |> Map.merge(%{conversation: conversation, task: nil, error: error})
    |> update_transcript(&Transcript.drop_empty/1)
    |> broadcast()
  end

  # ── State ─────────────────────────────────────────────────────────────────

  defp fresh(%{user: user} = state) do
    Map.merge(state, %{
      conversation: Conversation.new(toolbox: Toolbox, user: user),
      transcript: Transcript.new(),
      error: nil
    })
  end

  defp update_transcript(state, fun), do: Map.update!(state, :transcript, fun)

  defp ensure_remaining(%{remaining: nil, user: user} = state),
    do: %{state | remaining: Quota.remaining(user, LocalDate.today())}

  defp ensure_remaining(state), do: state

  # Runs in the session process so quota queries and the turn task it spawns
  # reach the caller's database connection under the test sandbox.
  defp adopt_callers(state, callers) do
    Process.put(:"$callers", callers)
    state
  end

  defp view(state) do
    %{
      entries: state.transcript.entries,
      busy: state.task != nil,
      pending: state.conversation.pending,
      error: state.error,
      remaining: state.remaining || 0
    }
  end

  defp broadcast(state) do
    Phoenix.PubSub.broadcast(@pubsub, topic(state.user), {:chat_session, view(state)})
    state
  end

  defp reply(state, value), do: {:reply, value, state, timeout(state)}
  defp noreply(state), do: {:noreply, state, timeout(state)}

  defp timeout(%{task: nil}), do: idle_ms()
  defp timeout(_busy), do: :infinity

  defp idle_ms do
    :residency_schedule
    |> Application.get_env(:chat, [])
    |> Keyword.get(:session_idle_ms, @default_idle_ms)
  end
end
