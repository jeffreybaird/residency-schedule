defmodule ResidencySchedule.ScheduleBuilder.HnfPostCallTest do
  use ResidencySchedule.DataCase, async: true

  alias ResidencySchedule.{Residents, Rotations, ScheduleBuilder, Schedules}
  alias ResidencySchedule.ScheduleBuilder.SlotCalendar

  setup do
    {:ok, schedule} = Schedules.upsert_schedule(2026, "2026–2027")
    own = resident(schedule, "R1-1")
    other = resident(schedule, "R1-2")
    [weekend, weekday | _] = Enum.drop_while(SlotCalendar.build_slots(2026), &(!&1.is_weekend))
    # Historic annual imports may be shifted one week from generated slots.
    saturday = Date.add(weekend.start_date, 7)
    sunday = Date.add(saturday, 1)
    friday = Date.add(sunday, 5)
    insert(other, :highland_weekend_days, saturday, sunday, weekend.slot_index)
    insert(other, :highland_night_float, sunday, friday, weekday.slot_index)

    %{
      schedule: schedule,
      own: own,
      other: other,
      weekend: weekend,
      weekday: weekday,
      saturday: saturday,
      sunday: sunday,
      friday: friday
    }
  end

  test "legacy annual builder accepts corrected Saturday P only with own following Sunday HNF",
       c do
    insert(c.own, :post_call, c.saturday, c.saturday, c.weekend.slot_index)
    insert(c.own, :highland_night_float, c.sunday, c.friday, c.weekday.slot_index)
    assert {:ok, state} = ScheduleBuilder.load_from_schedule(c.schedule.id)
    refute state.literal_dates?
    assert length(state.slots) == 100
    index = Enum.find_index(state.residents, &(&1.position_code == "R1-1"))
    assert state.assignments[{index, c.weekend.slot_index}] == :post_call
    assert state.assignments[{index, c.weekday.slot_index}] == :highland_night_float
  end

  test "another resident's Sunday HNF does not make Saturday P an annual shape", c do
    insert(c.own, :post_call, c.saturday, c.saturday, c.weekend.slot_index)
    assert {:error, _} = ScheduleBuilder.load_from_schedule(c.schedule.id)
  end

  test "a later own HNF does not make unmatched Saturday P an annual shape", c do
    insert(c.own, :post_call, c.saturday, c.saturday, c.weekend.slot_index)

    insert(
      c.own,
      :highland_night_float,
      Date.add(c.sunday, 7),
      Date.add(c.friday, 7),
      c.weekday.slot_index
    )

    assert {:error, _} = ScheduleBuilder.load_from_schedule(c.schedule.id)
  end

  test "corrected P compatibility does not permit irregular overlapping working assignments", c do
    insert(c.own, :post_call, c.saturday, c.saturday, c.weekend.slot_index)
    insert(c.own, :highland_night_float, c.sunday, c.friday, c.weekday.slot_index)
    insert(c.own, :strong_obstetrics, c.sunday, c.sunday, c.weekday.slot_index + 2)
    assert {:error, _} = ScheduleBuilder.load_from_schedule(c.schedule.id)
  end

  test "saving annual builder assignments cannot recreate Post Call on HNF Sunday" do
    assert {:ok, state} = ScheduleBuilder.generate(2027)
    [weekend, weekday | _] = Enum.drop_while(state.slots, &(!&1.is_weekend))

    state = %{
      state
      | assignments: %{
          {0, weekend.slot_index} => :post_call,
          {0, weekday.slot_index} => :highland_night_float
        }
    }

    assert {:ok, result} = ScheduleBuilder.save(state)

    resident =
      Enum.find(
        Residents.list_residents_for_schedule(result.schedule_id),
        &(&1.position_code == hd(state.residents).position_code)
      )

    rotations = Rotations.list_rotations_for_resident(resident.id)
    post_call = Enum.find(rotations, &(&1.rotation_type == "post_call"))
    hnf = Enum.find(rotations, &(&1.rotation_type == "highland_night_float"))
    assert {post_call.start_date, post_call.end_date} == {weekend.start_date, weekend.start_date}
    assert hnf.start_date == weekend.end_date
    assert Date.compare(post_call.end_date, hnf.start_date) == :lt
  end

  defp resident(schedule, position) do
    {:ok, resident} =
      Residents.insert_resident(schedule.id, %{
        position_code: position,
        residency_year: 1,
        schedule_number: String.last(position) |> String.to_integer(),
        name: "Example " <> position
      })

    resident
  end

  defp insert(resident, type, start_date, end_date, slot_index) do
    assert {:ok, 1} =
             Rotations.insert_rotations(resident.id, [
               %{
                 rotation_type: type,
                 start_date: start_date,
                 end_date: end_date,
                 slot_index: slot_index
               }
             ])
  end
end
