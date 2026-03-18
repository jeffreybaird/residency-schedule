defmodule ResidencySchedule.ScheduleBuilder.CoverageTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.ScheduleBuilder.Coverage

  @residents for i <- 0..31, do: %{residency_year: rem(i, 4) + 1}
  @weekday_slot %{slot_index: 0, is_weekend: false}
  @weekend_slot %{slot_index: 1, is_weekend: true}

  describe "required_coverage/0" do
    test "includes all 6 constrained rotation types" do
      cov = Coverage.required_coverage()
      assert Map.fetch!(cov, :strong_obstetrics) == 4
      assert Map.fetch!(cov, :oncology) == 4
      assert Map.fetch!(cov, :strong_gynecology) == 4
      assert Map.fetch!(cov, :ambulatory) == 4
      assert Map.fetch!(cov, :night_float) == 4
      assert Map.fetch!(cov, :highland_obstetrics) == 1
      assert Map.fetch!(cov, :strong_weekend_days) == 4
      assert Map.fetch!(cov, :strong_weekend_nights) == 4
    end
  end

  describe "count_for_slot/3" do
    test "counts only residents assigned the given type in the given slot" do
      assignments = %{
        {0, 0} => :strong_obstetrics,
        {1, 0} => :strong_obstetrics,
        {2, 0} => :oncology,
        {3, 0} => :strong_obstetrics,
        {0, 2} => :strong_obstetrics
      }
      assert Coverage.count_for_slot(assignments, 0, :strong_obstetrics) == 3
      assert Coverage.count_for_slot(assignments, 0, :oncology) == 1
      assert Coverage.count_for_slot(assignments, 2, :strong_obstetrics) == 1
    end

    test "returns 0 when no resident is on the rotation in the slot" do
      assert Coverage.count_for_slot(%{}, 0, :strong_obstetrics) == 0
    end
  end

  describe "coverage_warnings/3" do
    test "returns empty list when all constraints are satisfied" do
      # 4 OB + 4 ONC + 4 GYN + 4 AMB + 4 NF + 1 HHOB = 21 assignments
      # plus 4 SWD + 4 SWN on weekend slot
      assignments =
        Enum.reduce(0..3, %{}, fn year_offset, acc ->
          acc
          |> Map.put({year_offset, 0}, :strong_obstetrics)
          |> Map.put({year_offset + 4, 0}, :oncology)
          |> Map.put({year_offset + 8, 0}, :strong_gynecology)
          |> Map.put({year_offset + 12, 0}, :ambulatory)
          |> Map.put({year_offset + 16, 0}, :night_float)
        end)
        |> Map.put({20, 0}, :highland_obstetrics)
        |> then(fn a ->
          Enum.reduce(0..3, a, fn i, acc ->
            acc
            |> Map.put({i, 1}, :strong_weekend_days)
            |> Map.put({i + 4, 1}, :strong_weekend_nights)
          end)
        end)

      slots = [@weekday_slot, @weekend_slot]
      warnings = Coverage.coverage_warnings(assignments, slots, @residents)
      assert warnings == []
    end

    test "returns warning when OB is undercovered in a weekday slot" do
      assignments = %{{0, 0} => :strong_obstetrics}  # only 1 of needed 4
      warnings = Coverage.coverage_warnings(assignments, [@weekday_slot], @residents)
      ob_warning = Enum.find(warnings, & &1.rotation_type == :strong_obstetrics)
      assert ob_warning != nil
      assert ob_warning.actual == 1
      assert ob_warning.required == 4
      assert ob_warning.slot_index == 0
    end

    test "returns warning when HHOB is uncovered" do
      # No HHOB assigned at all
      assignments = %{}
      warnings = Coverage.coverage_warnings(assignments, [@weekday_slot], @residents)
      hhob_warning = Enum.find(warnings, & &1.rotation_type == :highland_obstetrics)
      assert hhob_warning != nil
      assert hhob_warning.actual == 0
      assert hhob_warning.required == 1
    end

    test "does not check weekday constraints on weekend slots" do
      assignments = %{}  # empty
      # Weekend slot only — should not have OB/ONC/GYN/AMB/NF warnings (those are weekday)
      warnings = Coverage.coverage_warnings(assignments, [@weekend_slot], @residents)
      weekday_types = [:strong_obstetrics, :oncology, :strong_gynecology, :ambulatory, :night_float]
      Enum.each(weekday_types, fn type ->
        refute Enum.any?(warnings, & &1.rotation_type == type)
      end)
    end

    test "does not check weekend constraints on weekday slots" do
      assignments = %{}
      warnings = Coverage.coverage_warnings(assignments, [@weekday_slot], @residents)
      weekend_types = [:strong_weekend_days, :strong_weekend_nights]
      Enum.each(weekend_types, fn type ->
        refute Enum.any?(warnings, & &1.rotation_type == type)
      end)
    end

    test "does not report warnings for FLOAT slots" do
      # All residents on FLOAT — curriculum day, coverage rules don't apply
      float_assignments =
        Enum.reduce(0..3, %{}, fn res_idx, acc ->
          Map.put(acc, {res_idx, 0}, :float)
        end)

      warnings = Coverage.coverage_warnings(float_assignments, [@weekday_slot], @residents)
      assert warnings == []
    end

    test "reports warnings across multiple slots" do
      slots = [
        %{slot_index: 0, is_weekend: false},
        %{slot_index: 2, is_weekend: false}
      ]
      assignments = %{}
      warnings = Coverage.coverage_warnings(assignments, slots, @residents)
      # Both slots should have warnings for all 6 weekday constraints
      slot_0_warnings = Enum.filter(warnings, & &1.slot_index == 0)
      slot_2_warnings = Enum.filter(warnings, & &1.slot_index == 2)
      assert length(slot_0_warnings) == 6
      assert length(slot_2_warnings) == 6
    end
  end

  describe "placement_warnings/2" do
    @weekday_slot_with_dates %{
      slot_index: 0,
      is_weekend: false,
      start_date: ~D[2026-06-29],
      end_date: ~D[2026-07-03]
    }
    @weekend_slot_with_dates %{
      slot_index: 1,
      is_weekend: true,
      start_date: ~D[2026-07-04],
      end_date: ~D[2026-07-05]
    }
    @float_slot %{
      slot_index: 50,
      is_weekend: false,
      start_date: ~D[2026-12-21],
      end_date: ~D[2026-12-27]
    }

    test "returns empty list when all placements are valid" do
      assignments = %{
        {0, 0} => :strong_obstetrics,
        {1, 1} => :strong_weekend_days,
        {2, 50} => :float
      }
      slots = [@weekday_slot_with_dates, @weekend_slot_with_dates, @float_slot]
      assert Coverage.placement_warnings(assignments, slots) == []
    end

    test "warns when weekday-only rotation is on a weekend slot" do
      assignments = %{{0, 1} => :strong_obstetrics}
      [warning] = Coverage.placement_warnings(assignments, [@weekend_slot_with_dates])
      assert warning.reason == :weekday_only
      assert warning.rotation_type == :strong_obstetrics
      assert warning.slot_index == 1
      assert warning.resident_index == 0
    end

    test "warns when weekend-only rotation is on a weekday slot" do
      assignments = %{{0, 0} => :strong_weekend_days}
      [warning] = Coverage.placement_warnings(assignments, [@weekday_slot_with_dates])
      assert warning.reason == :weekend_only
      assert warning.rotation_type == :strong_weekend_days
    end

    test "warns when non-float rotation is on a FLOAT slot" do
      assignments = %{{0, 50} => :ambulatory}
      [warning] = Coverage.placement_warnings(assignments, [@float_slot])
      assert warning.reason == :float_slot_only
      assert warning.rotation_type == :ambulatory
    end

    test "does not warn when :float is on a FLOAT slot" do
      assignments = %{{0, 50} => :float}
      assert Coverage.placement_warnings(assignments, [@float_slot]) == []
    end

    test "does not warn for vacation or post_call on weekday slots" do
      assignments = %{{0, 0} => :vacation, {1, 0} => :post_call}
      assert Coverage.placement_warnings(assignments, [@weekday_slot_with_dates]) == []
    end

    test "warns for vacation on weekend slot (weekday-only)" do
      assignments = %{{0, 1} => :vacation}
      [warning] = Coverage.placement_warnings(assignments, [@weekend_slot_with_dates])
      assert warning.reason == :weekday_only
    end

    test "warns for all four weekend-only rotations on weekday slots" do
      weekend_rotations = [:strong_weekend_days, :strong_weekend_nights, :highland_weekend_days, :highland_weekend_nights]
      assignments = weekend_rotations |> Enum.with_index() |> Map.new(fn {r, i} -> {{i, 0}, r} end)
      warnings = Coverage.placement_warnings(assignments, [@weekday_slot_with_dates])
      assert length(warnings) == 4
      assert Enum.all?(warnings, & &1.reason == :weekend_only)
    end

    test "returns warnings sorted by slot_index then resident_index" do
      slots = [@weekday_slot_with_dates, @weekend_slot_with_dates]
      assignments = %{
        {2, 0} => :strong_weekend_days,
        {0, 0} => :strong_weekend_days,
        {1, 1} => :strong_obstetrics
      }
      warnings = Coverage.placement_warnings(assignments, slots)
      indices = Enum.map(warnings, & {&1.slot_index, &1.resident_index})
      assert indices == Enum.sort(indices)
    end
  end
end
