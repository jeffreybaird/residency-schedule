defmodule ResidencySchedule.ScheduleFixtureIsolationTest do
  use ExUnit.Case, async: true
  doctest ResidencySchedule.ScheduleOrderingFixture

  alias Ecto.Adapters.SQL.Sandbox
  alias ResidencySchedule.{Repo, ScheduleOrderingFixture, Schedules}

  test "reverse-order schedule fixture does not deadlock with the resident filter fixture" do
    {older, newer} = ScheduleOrderingFixture.years()
    parent = self()
    # These are separate Sandbox checkouts, not tasks borrowing one shared connection.
    ordering = Task.async(fn -> insert_years(parent, :ordering, [newer, older]) end)
    # Mirrors ResidentsTest: setup inserts 2023, then the filter-options test inserts 2026.
    resident_filter = Task.async(fn -> insert_years(parent, :resident_filter, [2023, 2026]) end)

    try do
      assert_receive {:ready, :ordering, ordering_backend}, 15_000
      assert_receive {:ready, :resident_filter, resident_backend}, 15_000
      refute ordering_backend == resident_backend
      send(ordering.pid, :insert_second)
      send(resident_filter.pid, :insert_second)
      assert Task.await(ordering, 15_000) == :ok
      assert Task.await(resident_filter, 15_000) == :ok
    after
      Task.shutdown(ordering, :brutal_kill)
      Task.shutdown(resident_filter, :brutal_kill)
    end
  end

  defp insert_years(parent, label, [first, second]) do
    :ok = Sandbox.checkout(Repo)

    try do
      %{rows: [[backend]]} = Repo.query!("SELECT pg_backend_pid()")
      {:ok, _} = Schedules.upsert_schedule(first, Schedules.academic_year_label(first))
      send(parent, {:ready, label, backend})
      await_second_insert()
      {:ok, _} = Schedules.upsert_schedule(second, Schedules.academic_year_label(second))
      :ok
    rescue
      error in Postgrex.Error -> {:error, error.postgres.code}
    after
      Sandbox.checkin(Repo)
    end
  end

  defp await_second_insert do
    receive do
      :insert_second -> :ok
    after
      15_000 -> raise "Fixture coordination timed out before the second insert"
    end
  end
end
