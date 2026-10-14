defmodule ResidencySchedule.ScheduleCache do
  @moduledoc """
  Shares immutable prepared grids by database revision, repository and date.

  Builders run in their caller, keeping database ownership and tracing intact.
  Completed entries and coordinated work are bounded. Overload or cache restart
  falls back to an uncached build; this does not cap overall request concurrency.
  """
  use GenServer

  alias Ecto.Adapters.SQL
  alias ResidencySchedule.Repo
  alias ResidencySchedule.ScheduleCache.Revision

  @calculation_version 3
  @revision_retries 3
  @coordination_timeout 30_000

  @doc false
  def start_link(opts) do
    server_opts =
      case Keyword.get(opts, :name, __MODULE__) do
        nil -> []
        name -> [name: name]
      end

    GenServer.start_link(__MODULE__, opts, server_opts)
  end

  @doc """
  Fetches a shared value computed from one consistent database snapshot.

  The builder must only read shared schedule data, never sockets, authentication
  or user preferences. Transactions and SQL Sandbox connections bypass sharing.
  Exempt from doctest: integration tests exercise actual database commits,
  rollback, concurrency and prepared LiveView grids.
  """
  def fetch(%Date{} = today, builder) when is_function(builder, 0) do
    if bypass?() do
      builder.()
    else
      fetch_revision(today, builder, @revision_retries)
    end
  end

  @doc """
  Coordinates a caller-owned immutable build under an explicit internal key.

      iex> {:ok, cache} = ResidencySchedule.ScheduleCache.start_link(name: nil)
      iex> ResidencySchedule.ScheduleCache.fetch_key(:sample, fn -> [1, 2] end, cache)
      [1, 2]
      iex> ResidencySchedule.ScheduleCache.fetch_key(:sample, fn -> :not_called end, cache)
      [1, 2]
      iex> GenServer.stop(cache)
      :ok
  """
  def fetch_key(key, builder, server \\ __MODULE__) do
    case coordinate(key, builder, fn -> true end, server) do
      {:ok, value} -> value
      :uncached -> builder.()
    end
  end

  @impl true
  def init(opts) do
    {:ok,
     %{
       entries: %{},
       order: [],
       builds: %{},
       max_entries: Keyword.get(opts, :max_entries, 4),
       max_inflight: Keyword.get(opts, :max_inflight, 4),
       max_waiters: Keyword.get(opts, :max_waiters, 64)
     }}
  end

  @impl true
  def handle_call({:claim, key}, from, state) do
    case Map.fetch(state.entries, key) do
      {:ok, value} -> {:reply, {:hit, value}, touch(state, key)}
      :error -> claim_build(key, from, state)
    end
  end

  def handle_call({:publish, key, reference, value}, _, state) do
    case Map.get(state.builds, key) do
      %{reference: ^reference} = build ->
        Enum.each(build.waiters, &GenServer.reply(&1, {:hit, value}))
        state = state |> release_build(key, build) |> retain(key, value)
        {:reply, :ok, state}

      _ ->
        {:reply, :ignored, state}
    end
  end

  def handle_call({:abandon, key, reference}, _, state) do
    case Map.get(state.builds, key) do
      %{reference: ^reference} = build ->
        Enum.each(build.waiters, &GenServer.reply(&1, :retry))
        {:reply, :ok, release_build(state, key, build)}

      _ ->
        {:reply, :ignored, state}
    end
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _, _}, state) do
    case Enum.find(state.builds, fn {_, build} -> build.monitor == monitor end) do
      {key, build} ->
        Enum.each(build.waiters, &GenServer.reply(&1, :retry))
        {:noreply, release_build(state, key, build)}

      nil ->
        {:noreply, state}
    end
  end

  defp fetch_revision(today, builder, remaining) do
    revision = Revision.current()
    key = {@calculation_version, Repo.get_dynamic_repo(), revision, today}
    build = fn -> consistent_build(builder) end

    case coordinate(key, build, fn -> Revision.current() == revision end, __MODULE__) do
      {:ok, value} -> value
      :uncached -> build.()
      :stale when remaining > 0 -> fetch_revision(today, builder, remaining - 1)
      :stale -> build.()
    end
  end

  defp bypass? do
    metadata = Ecto.Adapter.lookup_meta(Repo.get_dynamic_repo())
    metadata.opts[:pool] == DBConnection.Ownership or Repo.in_transaction?()
  end

  defp consistent_build(builder) do
    {:ok, value} =
      Repo.transaction(fn ->
        SQL.query!(
          Repo.get_dynamic_repo(),
          "SET TRANSACTION ISOLATION LEVEL REPEATABLE READ, READ ONLY",
          []
        )

        builder.()
      end)

    value
  end

  defp coordinate(key, builder, valid?, server, retries \\ 3) do
    case call_cache(server, {:claim, key}) do
      {:hit, value} -> {:ok, value}
      {:build, reference} -> build_and_publish(key, reference, builder, valid?, server)
      :retry when retries > 0 -> coordinate(key, builder, valid?, server, retries - 1)
      :retry -> :uncached
      :uncached -> :uncached
    end
  end

  defp build_and_publish(key, reference, builder, valid?, server) do
    value = builder.()

    if valid?.() do
      call_cache(server, {:publish, key, reference, value})
      {:ok, value}
    else
      call_cache(server, {:abandon, key, reference})
      :stale
    end
  catch
    class, reason ->
      call_cache(server, {:abandon, key, reference})
      :erlang.raise(class, reason, __STACKTRACE__)
  end

  defp call_cache(server, message) do
    GenServer.call(server, message, @coordination_timeout)
  catch
    :exit, {_, {GenServer, :call, _}} -> :uncached
  end

  defp claim_build(key, from, state) do
    case Map.get(state.builds, key) do
      nil when map_size(state.builds) < state.max_inflight ->
        reference = make_ref()
        build = %{reference: reference, monitor: Process.monitor(elem(from, 0)), waiters: []}
        {:reply, {:build, reference}, put_in(state.builds[key], build)}

      %{waiters: waiters} = build when length(waiters) < state.max_waiters ->
        {:noreply, put_in(state.builds[key], %{build | waiters: [from | waiters]})}

      _ ->
        {:reply, :uncached, state}
    end
  end

  defp release_build(state, key, build) do
    Process.demonitor(build.monitor, [:flush])
    %{state | builds: Map.delete(state.builds, key)}
  end

  defp retain(state, key, value) do
    state = %{state | entries: Map.put(state.entries, key, value)} |> touch(key)
    retained = Enum.take(state.order, state.max_entries)
    %{state | order: retained, entries: Map.take(state.entries, retained)}
  end

  defp touch(state, key), do: %{state | order: [key | List.delete(state.order, key)]}
end
