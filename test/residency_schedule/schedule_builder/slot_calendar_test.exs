defmodule ResidencySchedule.ScheduleBuilder.SlotCalendarTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.ScheduleBuilder.SlotCalendar

  describe "build_slots/1" do
    test "returns exactly 100 slots (52 non-weekend + 48 weekend)" do
      slots = SlotCalendar.build_slots(2026)
      assert length(slots) == 100
      assert Enum.count(slots, & !&1.is_weekend) == 52
      assert Enum.count(slots, & &1.is_weekend) == 48
    end

    test "first slot starts on the Monday of the week containing July 1" do
      slots = SlotCalendar.build_slots(2026)
      first = hd(slots)
      assert Date.day_of_week(first.start_date) == 1
    end

    test "first slot starts on July 1 when July 1 is already a Monday" do
      # 2024-07-01 is a Monday
      slots = SlotCalendar.build_slots(2024)
      first = hd(slots)
      assert first.start_date == ~D[2024-07-01]
    end

    test "first slot starts on the preceding Monday when July 1 is not a Monday" do
      # 2026-07-01 is a Wednesday → preceding Monday is June 29
      slots = SlotCalendar.build_slots(2026)
      first = hd(slots)
      assert first.start_date == ~D[2026-06-29]
    end

    test "2025 academic year starts June 30 (Monday before July 1 Tuesday)" do
      slots = SlotCalendar.build_slots(2025)
      first = hd(slots)
      assert first.start_date == ~D[2025-06-30]
    end

    test "last slot ends on or before June 30 of the following year" do
      slots = SlotCalendar.build_slots(2026)
      last = List.last(slots)
      assert last.end_date.year <= 2027
      assert Date.compare(last.end_date, ~D[2027-06-30]) != :gt
    end

    test "slot_indices are sequential starting at 0" do
      slots = SlotCalendar.build_slots(2026)
      indices = Enum.map(slots, & &1.slot_index)
      assert indices == Enum.to_list(0..99)
    end

    test "regular weekday slots cover Mon–Fri (start on Monday, end on Friday)" do
      slots = SlotCalendar.build_slots(2026)

      regular_weekday =
        slots
        |> Enum.filter(& !&1.is_weekend)
        |> Enum.reject(fn s -> Date.diff(s.end_date, s.start_date) == 6 end)

      assert length(regular_weekday) == 48

      Enum.each(regular_weekday, fn s ->
        assert Date.day_of_week(s.start_date) == 1, "start_date #{s.start_date} should be Monday"
        assert Date.day_of_week(s.end_date) == 5, "end_date #{s.end_date} should be Friday"
        assert Date.diff(s.end_date, s.start_date) == 4
      end)
    end

    test "weekend slots cover Sat–Sun (start on Saturday, end on Sunday)" do
      slots = SlotCalendar.build_slots(2026)
      weekends = Enum.filter(slots, & &1.is_weekend)
      assert length(weekends) == 48

      Enum.each(weekends, fn s ->
        assert Date.day_of_week(s.start_date) == 6, "start_date #{s.start_date} should be Saturday"
        assert Date.day_of_week(s.end_date) == 7, "end_date #{s.end_date} should be Sunday"
        assert Date.diff(s.end_date, s.start_date) == 1
      end)
    end

    test "FLOAT slots span Mon–Sun (7 days, is_weekend: false)" do
      slots = SlotCalendar.build_slots(2026)
      float_slots = Enum.filter(slots, fn s -> Date.diff(s.end_date, s.start_date) == 6 end)
      assert length(float_slots) == 4

      Enum.each(float_slots, fn s ->
        assert s.is_weekend == false
        assert Date.day_of_week(s.start_date) == 1, "FLOAT start #{s.start_date} should be Monday"
        assert Date.day_of_week(s.end_date) == 7, "FLOAT end #{s.end_date} should be Sunday"
      end)
    end

    test "each regular weekend slot immediately follows the preceding regular weekday slot" do
      slots = SlotCalendar.build_slots(2026)

      regular_weekday =
        slots
        |> Enum.filter(& !&1.is_weekend)
        |> Enum.reject(fn s -> Date.diff(s.end_date, s.start_date) == 6 end)

      weekends = Enum.filter(slots, & &1.is_weekend)
      assert length(regular_weekday) == 48
      assert length(weekends) == 48

      Enum.zip(regular_weekday, weekends)
      |> Enum.each(fn {wd, we} ->
        assert Date.diff(we.start_date, wd.end_date) == 1,
          "weekend #{we.start_date} should be day after weekday end #{wd.end_date}"
      end)
    end
  end

  describe "slots_for_window/3" do
    setup do
      slots = SlotCalendar.build_slots(2026)
      {:ok, slots: slots}
    end

    test "returns exactly window_size weekday slots", %{slots: slots} do
      window = SlotCalendar.slots_for_window(slots, 0, 4)
      weekday_count = Enum.count(window, & !&1.is_weekend)
      assert weekday_count == 4
    end

    test "includes weekend slots within the window range", %{slots: slots} do
      window = SlotCalendar.slots_for_window(slots, 0, 4)
      # 4 weekday + up to 4 weekend slots between them
      assert length(window) > 4
    end

    test "clamps at the start boundary (slot_index 0)" do
      slots = SlotCalendar.build_slots(2026)
      window = SlotCalendar.slots_for_window(slots, 0, 4)
      assert hd(window).slot_index == 0
    end

    test "clamps at the end boundary (last slots)" do
      slots = SlotCalendar.build_slots(2026)
      last_wd_index = slots |> Enum.filter(& !&1.is_weekend) |> List.last() |> Map.fetch!(:slot_index)
      window = SlotCalendar.slots_for_window(slots, last_wd_index, 4)
      wd_count = Enum.count(window, & !&1.is_weekend)
      assert wd_count == 1
    end

    test "returns empty list when slot_index is beyond all slots", %{slots: slots} do
      window = SlotCalendar.slots_for_window(slots, 9999, 4)
      assert window == []
    end

    test "default window_size is 4", %{slots: slots} do
      window = SlotCalendar.slots_for_window(slots, 0)
      weekday_count = Enum.count(window, & !&1.is_weekend)
      assert weekday_count == 4
    end
  end

  describe "float_slot_indices/2" do
    setup do
      slots = SlotCalendar.build_slots(2025)
      {:ok, slots: slots, float_slots: SlotCalendar.float_slot_indices(2025, slots)}
    end

    test "returns exactly 4 float slot indices (2 holiday + 2 end-of-year)", %{float_slots: float_slots} do
      assert MapSet.size(float_slots) == 4
    end

    test "all returned indices are non-weekend slots", %{slots: slots, float_slots: float_slots} do
      non_weekend_indices = slots |> Enum.filter(& !&1.is_weekend) |> MapSet.new(& &1.slot_index)
      assert MapSet.subset?(float_slots, non_weekend_indices)
    end

    test "all float slots span 7 days", %{slots: slots, float_slots: float_slots} do
      float_slot_list = Enum.filter(slots, fn s -> s.slot_index in float_slots end)

      Enum.each(float_slot_list, fn s ->
        assert Date.diff(s.end_date, s.start_date) == 6,
          "FLOAT slot #{s.slot_index} (#{s.start_date}–#{s.end_date}) should span 7 days"
      end)
    end

    test "holiday FLOAT slot starts on Dec 22 for 2025-2026" do
      # First Monday of Jan 2026 is Jan 5; 14 days before = Dec 22
      slots = SlotCalendar.build_slots(2025)
      float_slots = SlotCalendar.float_slot_indices(2025, slots)
      dec_22_slot = Enum.find(slots, fn s -> !s.is_weekend and s.start_date == ~D[2025-12-22] end)
      assert dec_22_slot != nil
      assert dec_22_slot.slot_index in float_slots
    end

    test "holiday FLOAT includes the following week (Dec 29 for 2025-2026)" do
      slots = SlotCalendar.build_slots(2025)
      float_slots = SlotCalendar.float_slot_indices(2025, slots)
      dec_29_slot = Enum.find(slots, fn s -> !s.is_weekend and s.start_date == ~D[2025-12-29] end)
      assert dec_29_slot != nil
      assert dec_29_slot.slot_index in float_slots
    end

    test "holiday FLOAT week ends on Jan 4 (Sun) for 2025-2026" do
      slots = SlotCalendar.build_slots(2025)
      float_slots = SlotCalendar.float_slot_indices(2025, slots)
      dec_22_slot = Enum.find(slots, fn s -> s.slot_index in float_slots and s.start_date == ~D[2025-12-22] end)
      assert dec_22_slot != nil
      assert dec_22_slot.end_date == ~D[2025-12-28]
      dec_29_slot = Enum.find(slots, fn s -> s.slot_index in float_slots and s.start_date == ~D[2025-12-29] end)
      assert dec_29_slot != nil
      assert dec_29_slot.end_date == ~D[2026-01-04]
    end

    test "end-of-year FLOAT starts 14 days before 2026-2027 term start (June 29)" do
      # 2026-2027 term starts June 29, so end-of-year FLOAT starts June 15
      slots = SlotCalendar.build_slots(2025)
      float_slots = SlotCalendar.float_slot_indices(2025, slots)
      june_15_slot = Enum.find(slots, fn s -> !s.is_weekend and s.start_date == ~D[2026-06-15] end)
      assert june_15_slot != nil
      assert june_15_slot.slot_index in float_slots
    end

    test "different academic years produce float slots at their respective calendar dates" do
      slots_2026 = SlotCalendar.build_slots(2026)
      float_2026 = SlotCalendar.float_slot_indices(2026, slots_2026)
      # 2026-2027 holiday FLOAT: first Monday of Jan 2027 is Jan 4; 14 days before = Dec 21
      dec_21_slot = Enum.find(slots_2026, fn s -> !s.is_weekend and s.start_date == ~D[2026-12-21] end)
      assert dec_21_slot != nil
      assert dec_21_slot.slot_index in float_2026
    end
  end
end
