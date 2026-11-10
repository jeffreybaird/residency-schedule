if System.get_env("RESIDENCY_FIXTURE_GROUP_PROBE") == "1" do
  defmodule ResidencySchedule.SharedFixtureGroupProbe do
    @moduledoc false

    def start do
      pid = spawn(fn -> coordinate(nil, nil, false) end)
      Process.register(pid, __MODULE__)
    end

    def fixture do
      request(:fixture)
    end

    def independent do
      request(:independent)
    end

    def finished do
      send(__MODULE__, {:finished, self()})
    end

    defp request(kind) do
      ref = make_ref()
      send(__MODULE__, {kind, self(), ref})

      receive do
        {^ref, result} -> result
      after
        5_000 -> {:error, :independent_module_could_not_overlap_shared_fixtures}
      end
    end

    defp coordinate(fixture, independent, released?) do
      receive do
        {:fixture, pid, ref} when released? ->
          send(pid, {ref, :ok})
          coordinate({pid, ref}, independent, true)

        {:fixture, pid, ref} ->
          release({pid, ref}, independent)

        {:independent, pid, ref} ->
          release(fixture, {pid, ref})

        {:finished, pid} when not is_nil(fixture) and elem(fixture, 0) == pid ->
          coordinate(nil, independent, released?)
      end
    end

    defp release(nil, independent), do: coordinate(nil, independent, false)
    defp release(fixture, nil), do: coordinate(fixture, nil, false)

    defp release({fixture_pid, fixture_ref} = fixture, {pure_pid, pure_ref} = independent) do
      send(fixture_pid, {fixture_ref, :ok})
      send(pure_pid, {pure_ref, :ok})
      coordinate(fixture, independent, true)
    end
  end

  ResidencySchedule.SharedFixtureGroupProbe.start()

  # Registration order is intentional: without a shared group these two cases
  # occupy both scheduler slots before the independent case can release them.
  defmodule ResidencySchedule.SharedFixtureDataProbe do
    use ResidencySchedule.DataCase, async: true

    test "a DataCase fixture can share scheduler capacity with independent work", context do
      assert context.async
      assert {:ok, _} = ResidencySchedule.Schedules.upsert_schedule(2023, "2023–2024")

      try do
        assert ResidencySchedule.SharedFixtureGroupProbe.fixture() == :ok
      after
        ResidencySchedule.SharedFixtureGroupProbe.finished()
      end
    end
  end

  defmodule ResidencySchedule.SharedFixtureConnProbe do
    use ResidencyScheduleWeb.ConnCase, async: true

    test "a ConnCase fixture uses the same shared resource group", context do
      assert context.async
      assert %Plug.Conn{} = context.conn
      assert {:ok, _} = ResidencySchedule.Schedules.upsert_schedule(2023, "2023–2024")

      try do
        assert ResidencySchedule.SharedFixtureGroupProbe.fixture() == :ok
      after
        ResidencySchedule.SharedFixtureGroupProbe.finished()
      end
    end
  end

  defmodule ResidencySchedule.IndependentFixtureGroupProbe do
    use ExUnit.Case, async: true

    test "independent work overlaps a shared database fixture" do
      assert ResidencySchedule.SharedFixtureGroupProbe.independent() == :ok
    end
  end
end
