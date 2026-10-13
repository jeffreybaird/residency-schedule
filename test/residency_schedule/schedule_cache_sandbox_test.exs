defmodule ResidencySchedule.ScheduleCacheSandboxTest do
  use ResidencySchedule.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias ResidencySchedule.ScheduleCache

  test "sandbox reads never publish or reuse cross-test cached state" do
    assert %{rows: [["on"]]} =
             SQL.query!(
               Repo.get_dynamic_repo(),
               "SELECT current_setting('residency_schedule.skip_cache_revision', true)",
               []
             )

    assert ScheduleCache.fetch(~D[2095-10-13], fn -> :first_uncommitted_value end) ==
             :first_uncommitted_value

    assert ScheduleCache.fetch(~D[2095-10-13], fn -> :second_uncommitted_value end) ==
             :second_uncommitted_value
  end
end
