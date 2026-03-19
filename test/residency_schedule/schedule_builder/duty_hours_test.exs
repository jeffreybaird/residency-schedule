defmodule ResidencySchedule.ScheduleBuilder.DutyHoursTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.ScheduleBuilder.DutyHours

  describe "hours_for_rotation/1" do
    test "returns 12 for 12-hour rotations" do
      twelve_hour = [
        :strong_obstetrics, :oncology, :strong_gynecology, :night_float,
        :highland_obstetrics, :strong_weekend_days, :strong_weekend_nights,
        :highland_gynecology, :highland_weekend_nights, :highland_weekend_days,
        :highland_night_float
      ]
      Enum.each(twelve_hour, fn type ->
        assert DutyHours.hours_for_rotation(type) == 12, "expected 12 for #{type}"
      end)
    end

    test "returns 9 for 9-hour rotations" do
      nine_hour = [:ambulatory, :rei, :urogynecology, :elective, :swing, :ultrasound]
      Enum.each(nine_hour, fn type ->
        assert DutyHours.hours_for_rotation(type) == 9, "expected 9 for #{type}"
      end)
    end

    test "returns 0 for off-service rotations" do
      zero_hour = [:vacation, :float, :post_call, :away_rotation]
      Enum.each(zero_hour, fn type ->
        assert DutyHours.hours_for_rotation(type) == 0, "expected 0 for #{type}"
      end)
    end

    test "returns 0 for nil" do
      assert DutyHours.hours_for_rotation(nil) == 0
    end
  end

  describe "slot_hours/2" do
    test "weekday OB slot = 60 hrs (12 * 5 days)" do
      assert DutyHours.slot_hours(:strong_obstetrics, %{is_weekend: false}) == 60
    end

    test "weekend OB slot = 24 hrs (12 * 2 days)" do
      assert DutyHours.slot_hours(:strong_obstetrics, %{is_weekend: true}) == 24
    end

    test "weekday AMB slot = 45 hrs (9 * 5 days)" do
      assert DutyHours.slot_hours(:ambulatory, %{is_weekend: false}) == 45
    end

    test "weekend AMB slot = 18 hrs (9 * 2 days)" do
      assert DutyHours.slot_hours(:ambulatory, %{is_weekend: true}) == 18
    end

    test "weekday Vac slot = 0 hrs" do
      assert DutyHours.slot_hours(:vacation, %{is_weekend: false}) == 0
    end
  end

  describe "weekly_avg_hours/3" do
    test "4 weekday AMB slots = 45.0 avg (no weekends)" do
      slots = for i <- [0, 2, 4, 6], do: %{slot_index: i, is_weekend: false}
      assignments = for i <- [0, 2, 4, 6], into: %{}, do: {{0, i}, :ambulatory}
      assert DutyHours.weekly_avg_hours(0, slots, assignments) == 45.0
    end

    test "4 weekday OB + 4 weekend OB slots = (60*4 + 24*4) / 4 = 84.0" do
      slots =
        for {i, is_we} <- [{0, false}, {1, true}, {2, false}, {3, true},
                            {4, false}, {5, true}, {6, false}, {7, true}] do
          %{slot_index: i, is_weekend: is_we}
        end
      assignments =
        for i <- [0, 1, 2, 3, 4, 5, 6, 7], into: %{} do
          {{0, i}, :strong_obstetrics}
        end
      assert DutyHours.weekly_avg_hours(0, slots, assignments) == 84.0
    end

    test "unassigned slots count as 0 hours (treated as float)" do
      slots = for i <- [0, 2, 4, 6], do: %{slot_index: i, is_weekend: false}
      assignments = %{{0, 0} => :ambulatory}
      avg = DutyHours.weekly_avg_hours(0, slots, assignments)
      assert avg == 45.0 / 4
    end

    test "returns 0.0 when there are no weekday slots" do
      slots = [%{slot_index: 1, is_weekend: true}]
      assignments = %{{0, 1} => :strong_obstetrics}
      assert DutyHours.weekly_avg_hours(0, slots, assignments) == 0.0
    end
  end

  describe "violations/3" do
    defp build_window(res_idx, rotation_type, slot_count) do
      slots =
        for i <- 0..(slot_count - 1) do
          %{slot_index: i * 2, is_weekend: false}
        end
      assignments =
        for i <- 0..(slot_count - 1), into: %{} do
          {{res_idx, i * 2}, rotation_type}
        end
      {slots, assignments}
    end

    test "returns empty list when all windows are within 80 hr avg" do
      # AMB only: 45 hrs/week — well under limit
      {slots, assignments} = build_window(0, :ambulatory, 4)
      residents = [%{residency_year: 1}]
      assert DutyHours.violations(assignments, slots, residents) == []
    end

    test "returns empty list for OB-only weekday (60 hr/week, no weekends)" do
      # 60 hrs/week — under 80 limit
      {slots, assignments} = build_window(0, :strong_obstetrics, 4)
      residents = [%{residency_year: 1}]
      assert DutyHours.violations(assignments, slots, residents) == []
    end

    test "flags a window when OB weekday + OB weekend exceeds 80 hrs avg" do
      # Each week: 60 (weekday) + 24 (weekend) = 84 hrs avg
      slots =
        for {i, is_we} <- Enum.flat_map(0..3, fn w -> [{w * 2, false}, {w * 2 + 1, true}] end) do
          %{slot_index: i, is_weekend: is_we}
        end
      assignments =
        for i <- 0..7, into: %{} do
          {{0, i}, :strong_obstetrics}
        end
      residents = [%{residency_year: 1}]
      viols = DutyHours.violations(assignments, slots, residents)
      assert length(viols) > 0
      assert hd(viols).resident_index == 0
      assert hd(viols).weekly_avg > 80
    end

    test "only reports violations for the affected resident" do
      # Resident 0: over limit; Resident 1: fine
      slots =
        for {i, is_we} <- Enum.flat_map(0..3, fn w -> [{w * 2, false}, {w * 2 + 1, true}] end) do
          %{slot_index: i, is_weekend: is_we}
        end
      assignments =
        Enum.reduce(0..7, %{}, fn i, acc ->
          acc
          |> Map.put({0, i}, :strong_obstetrics)
          |> Map.put({1, i}, :ambulatory)
        end)
      residents = [%{residency_year: 1}, %{residency_year: 2}]
      viols = DutyHours.violations(assignments, slots, residents)
      assert Enum.all?(viols, & &1.resident_index == 0)
    end
  end
end
