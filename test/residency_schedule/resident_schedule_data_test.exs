defmodule ResidencySchedule.ResidentScheduleDataTest do
  use ResidencySchedule.DataCase

  import ResidencySchedule.QgendaDetailFixtures
  alias ResidencySchedule.{DetailedSchedules, Rotations, ScheduleFixtures, ShiftOverrides}

  test "shared inputs exactly preserve detailed projection, activities, effective maps and raw date slots" do
    data = seed_detail_roster()
    {:ok, preview} = detail_preview()
    {:ok, _} = DetailedSchedules.commit(preview, ScheduleFixtures.admin_user())
    assert DetailedSchedules.list_for_resident(data.iris.id) != []

    expected = %{
      rotations: Rotations.projected_rotations_for_resident(data.iris.id),
      activities: DetailedSchedules.list_for_resident(data.iris.id),
      effective_entries: Rotations.effective_segments_for_resident(data.iris.id),
      date_slots: Rotations.list_schedule_date_slots(data.schedule.id)
    }

    assert Rotations.resident_schedule_data(data.iris) == expected

    assert Enum.any?(expected.date_slots, fn {_, start_date, end_date} ->
             start_date == ~D[2026-12-28] and end_date == ~D[2027-01-03]
           end)
  end

  test "incoming coverage from another schedule retains exact effective segment semantics" do
    data = ScheduleFixtures.seed_mini_schedule()
    earlier = ScheduleFixtures.seed_prior_year_for_clare(data)
    [rotation | _] = Rotations.list_rotations_for_resident(earlier.clare_r1.id)

    {:ok, _} =
      ShiftOverrides.create_override(%{
        rotation_id: rotation.id,
        covering_schedule_resident_id: data.mary.id,
        override_start_date: rotation.start_date,
        override_end_date: rotation.end_date
      })

    expected = Rotations.effective_segments_for_resident(data.mary.id)
    assert Enum.any?(expected, & &1.is_coverage)
    actual = Rotations.resident_schedule_data(data.mary)
    assert actual.effective_entries == expected
    assert actual.rotations == Rotations.projected_rotations_for_resident(data.mary.id)
    assert actual.date_slots == Rotations.list_schedule_date_slots(data.schedule.id)
  end
end
