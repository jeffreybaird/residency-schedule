defmodule ResidencySchedule.TaskMappings.FridayEnrichmentRunner do
  @moduledoc """
  Owns the single administrator-initiated Friday maintenance operation.

  Preview selections stay on the server. Work belongs to the application and
  continues when the administrator leaves the page; only aggregate results are
  retained in memory.
  """

  use GenServer

  alias ResidencySchedule.Accounts.User
  alias ResidencySchedule.Repo
  alias ResidencySchedule.TaskMappings.FridayEnrichment

  @supervisor ResidencySchedule.TaskMappings.FridayEnrichmentTaskSupervisor
  @topic "maintenance:friday-policy"
  @notification :friday_policy_enrichment_status_changed
  @preview_counts ~w(scanned eligible unchanged protected held conflicting not_applicable)a
  @apply_counts ~w(scanned attested unchanged protected held conflicting not_applicable)a

  @doc """
  Starts the maintenance coordinator.

      iex> {:ok, coordinator} = ResidencySchedule.TaskMappings.FridayEnrichmentRunner.start_link(name: nil)
      iex> GenServer.stop(coordinator)
      :ok
  """
  def start_link(opts \\ []) do
    options = if name = Keyword.get(opts, :name, __MODULE__), do: [name: name], else: []
    GenServer.start_link(__MODULE__, nil, options)
  end

  @doc """
  Previews a selection for a currently approved administrator.

      iex> ctx = ResidencySchedule.FridayEnrichmentFixtures.historical_source()
      iex> {:ok, preview} = ResidencySchedule.TaskMappings.FridayEnrichmentRunner.preview(ctx.admin)
      iex> preview.counts.eligible
      1
  """
  def preview(user, opts \\ []), do: GenServer.call(__MODULE__, {:preview, user, opts}, :infinity)

  @doc """
  Starts applying the administrator's server-retained preview.

      iex> ctx = ResidencySchedule.FridayEnrichmentFixtures.historical_source()
      iex> {:ok, preview} = ResidencySchedule.TaskMappings.FridayEnrichmentRunner.preview(ctx.admin)
      iex> {:ok, run} = ResidencySchedule.TaskMappings.FridayEnrichmentRunner.start(ctx.admin, preview.token)
      iex> run.operation
      :apply
      iex> ResidencySchedule.FridayEnrichmentUIFixtures.await_terminal(ctx.admin).counts.attested
      1
  """
  def start(user, token), do: GenServer.call(__MODULE__, {:start, user, token})

  @doc """
  Returns aggregate maintenance status to a currently approved administrator.

      iex> ctx = ResidencySchedule.FridayEnrichmentFixtures.historical_source()
      iex> {:ok, preview} = ResidencySchedule.TaskMappings.FridayEnrichmentRunner.preview(ctx.admin)
      iex> {:ok, status} = ResidencySchedule.TaskMappings.FridayEnrichmentRunner.status(ctx.admin)
      iex> status.preview == preview and status.run.status == :completed
      true
  """
  def status(user), do: GenServer.call(__MODULE__, {:status, user})

  @impl true
  def init(nil), do: {:ok, %{operation: nil, preview: nil, run: nil, last_run: nil}}

  @impl true
  def handle_call({:status, user}, _from, state) do
    reply =
      with {:ok, id} <- authorize(user) do
        preview =
          case state.preview do
            %{user_id: ^id} = preview -> Map.take(preview, [:token, :counts])
            _ -> nil
          end

        {:ok, %{run: state.run, preview: preview, last_run: state.last_run}}
      end

    {:reply, reply, state}
  end

  def handle_call({:preview, user, opts}, from, state) do
    with {:ok, id} <- authorize(user),
         :ok <- available(state),
         {:ok, operation} <- launch(:preview, id, fn -> FridayEnrichment.preview(opts) end) do
      state = begin_operation(state, %{operation | from: from})
      {:noreply, %{state | preview: nil}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call({:start, user, token}, _from, state) do
    with {:ok, id} <- authorize(user),
         :ok <- available(state),
         {:ok, scope} <- reviewed_scope(state.preview, id, token),
         {:ok, operation} <- launch(:apply, id, fn -> FridayEnrichment.apply(scope) end) do
      state = begin_operation(state, operation)
      {:reply, {:ok, state.run}, %{state | preview: nil}}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_info({:friday_operation_result, key, result}, %{operation: %{key: key}} = state) do
    {:noreply, put_in(state.operation.result, result)}
  end

  def handle_info(
        {:DOWN, monitor, :process, _pid, _reason},
        %{operation: %{monitor: monitor}} = state
      ) do
    # Publish completion only after the worker exits, so the next operation can
    # immediately use the supervisor's single worker slot.
    {:noreply, finish_operation(state)}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp authorize(%User{id: id}) when is_integer(id), do: authorize_id(id)
  defp authorize(_user), do: {:error, :forbidden}

  defp authorize_id(id) do
    case Repo.get(User, id) do
      %User{role: :admin, approved: true, denied: false} -> {:ok, id}
      _ -> {:error, :forbidden}
    end
  end

  defp available(%{operation: nil}) do
    if Task.Supervisor.children(@supervisor) == [], do: :ok, else: {:error, :busy}
  end

  defp available(_state), do: {:error, :busy}

  defp reviewed_scope(%{user_id: id, token: token, scope: scope}, id, token)
       when is_binary(token),
       do: {:ok, scope}

  defp reviewed_scope(_preview, _id, _token), do: {:error, :invalid_preview}

  defp launch(kind, id, work) do
    owner = self()
    key = make_ref()

    case Task.Supervisor.start_child(@supervisor, fn ->
           result = safely_run(id, work)
           send(owner, {:friday_operation_result, key, result})
         end) do
      {:ok, pid} ->
        {:ok,
         %{
           kind: kind,
           user_id: id,
           key: key,
           monitor: Process.monitor(pid),
           result: nil,
           from: nil
         }}

      {:error, :max_children} ->
        {:error, :busy}

      {:error, _reason} ->
        {:error, :run_failed}
    end
  end

  defp safely_run(id, work) do
    with {:ok, ^id} <- authorize_id(id), do: work.()
  rescue
    _error -> {:error, :run_failed}
  catch
    _kind, _reason -> {:error, :run_failed}
  end

  defp begin_operation(state, operation) do
    run = %{
      operation: operation.kind,
      status: :running,
      started_at: DateTime.utc_now(),
      finished_at: nil,
      counts: nil,
      error: nil
    }

    notify()
    %{state | operation: operation, run: run}
  end

  defp finish_operation(%{operation: %{kind: :preview} = operation} = state) do
    result =
      with {:ok, _id} <- authorize_id(operation.user_id),
           {:ok, %{scope: scope, counts: counts}} <- operation.result do
        {:ok,
         %{
           token: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false),
           user_id: operation.user_id,
           scope: scope,
           counts: Map.take(counts, @preview_counts)
         }}
      end

    case result do
      {:ok, preview} ->
        GenServer.reply(operation.from, {:ok, Map.take(preview, [:token, :counts])})
        complete(state, preview.counts, nil, preview)

      error ->
        reason = public_error(error)
        GenServer.reply(operation.from, {:error, reason})
        complete(state, nil, reason, nil)
    end
  end

  defp finish_operation(state) do
    case state.operation.result do
      {:ok, counts} when is_map(counts) ->
        complete(state, Map.take(counts, @apply_counts), nil, nil)

      error ->
        complete(state, nil, public_error(error), nil)
    end
  end

  defp complete(state, counts, error, preview) do
    run = %{
      state.run
      | status: if(error, do: :failed, else: :completed),
        counts: counts,
        error: error,
        finished_at: DateTime.utc_now()
    }

    last_run = if run.operation == :apply, do: run, else: state.last_run
    notify()
    %{state | operation: nil, run: run, preview: preview, last_run: last_run}
  end

  defp public_error({:error, reason}) when reason in [:forbidden, :write_failed], do: reason
  defp public_error(_error), do: :run_failed

  defp notify do
    Phoenix.PubSub.broadcast(ResidencySchedule.PubSub, @topic, @notification)
  end
end
