defmodule ResidencySchedule.ActivityNameCapitalizationTest do
  use ResidencySchedule.DataCase
  import ResidencySchedule.QgendaDetailFixtures
  alias ResidencySchedule.DetailedSchedules

  test "all activities use resolved full-name capitalization while keeping raw staff evidence" do
    data = seed_detail_roster()
    {:ok, preview} = detail_preview()
    {:ok, _} = DetailedSchedules.commit(preview, ResidencySchedule.ScheduleFixtures.admin_user())
    activities = DetailedSchedules.list_for_resident(data.iris.id, ~D[2026-12-28])
    assert Enum.any?(activities, &(&1.raw_staff == "IRIS REED"))
    assert Enum.all?(activities, &(&1.display_name == "Iris Reed"))

    assert Enum.any?(activities, fn activity ->
             Enum.any?(activity.sources, &(&1.raw_staff == "IRIS REED"))
           end)
  end
end
