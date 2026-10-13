defmodule ResidencySchedule.ScheduleCacheTest do
  use ExUnit.Case, async: false

  alias ResidencySchedule.ScheduleCache

  doctest ResidencySchedule.ScheduleCache

  setup do
    cache = start_supervised!({ScheduleCache, name: nil, max_entries: 4})
    %{cache: cache}
  end

  test "returns cached immutable values and retains only four completed keys", %{cache: cache} do
    for key <- 1..5 do
      assert %{rows: [key]} == ScheduleCache.fetch_key(key, fn -> %{rows: [key]} end, cache)
    end

    for key <- 2..5 do
      assert %{rows: [key]} ==
               ScheduleCache.fetch_key(key, fn -> flunk("rebuilt retained key") end, cache)
    end

    assert :rebuilt == ScheduleCache.fetch_key(1, fn -> :rebuilt end, cache)
  end

  test "concurrent callers share one successful build in its original caller process", %{
    cache: cache
  } do
    owner = self()

    first =
      Task.async(fn ->
        caller = self()

        ScheduleCache.fetch_key(
          :shared,
          fn ->
            assert self() == caller
            send(owner, {:building, self()})

            receive do
              :release -> %{rows: [1, 2]}
            end
          end,
          cache
        )
      end)

    assert_receive {:building, builder}

    waiters =
      for _ <- 1..6 do
        Task.async(fn ->
          ScheduleCache.fetch_key(:shared, fn -> flunk("duplicate builder") end, cache)
        end)
      end

    for waiter <- waiters, do: assert(Task.yield(waiter, 25) == nil)
    send(builder, :release)
    assert Task.await(first) == %{rows: [1, 2]}
    for waiter <- waiters, do: assert(Task.await(waiter) == %{rows: [1, 2]})
  end

  test "a failed builder preserves the error and a later caller can rebuild", %{cache: cache} do
    assert_raise RuntimeError, "synthetic builder failure", fn ->
      ScheduleCache.fetch_key(:failure, fn -> raise "synthetic builder failure" end, cache)
    end

    assert :recovered == ScheduleCache.fetch_key(:failure, fn -> :recovered end, cache)

    assert :recovered ==
             ScheduleCache.fetch_key(
               :failure,
               fn -> flunk("failed to retain recovery") end,
               cache
             )
  end

  test "a killed builder releases its waiting caller", %{cache: cache} do
    owner = self()

    builder =
      spawn(fn ->
        ScheduleCache.fetch_key(
          :crash,
          fn ->
            send(owner, :building)

            receive do
              :never -> :unused
            end
          end,
          cache
        )
      end)

    monitor = Process.monitor(builder)
    assert_receive :building
    waiter = Task.async(fn -> ScheduleCache.fetch_key(:crash, fn -> :takeover end, cache) end)
    Process.exit(builder, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^builder, :killed}
    assert Task.await(waiter) == :takeover
  end

  test "a restarted cache rebuilds instead of serving abandoned state", %{cache: cache} do
    assert :old == ScheduleCache.fetch_key(:restart, fn -> :old end, cache)
    assert :ok = stop_supervised(ScheduleCache)
    restarted = start_supervised!({ScheduleCache, name: nil, max_entries: 4})
    assert :new == ScheduleCache.fetch_key(:restart, fn -> :new end, restarted)
  end

  test "inflight capacity uses an uncached fallback instead of queuing more keys" do
    cache =
      start_supervised!(
        Supervisor.child_spec({ScheduleCache, name: nil, max_inflight: 1}, id: :small_cache)
      )

    owner = self()

    first =
      Task.async(fn ->
        ScheduleCache.fetch_key(
          :blocked,
          fn ->
            send(owner, :blocked_builder)

            receive do
              :release -> :finished
            end
          end,
          cache
        )
      end)

    assert_receive :blocked_builder
    assert :overflow == ScheduleCache.fetch_key(:overflow, fn -> :overflow end, cache)
    assert :uncached == ScheduleCache.fetch_key(:overflow, fn -> :uncached end, cache)
    send(first.pid, :release)
    assert Task.await(first) == :finished
  end
end
