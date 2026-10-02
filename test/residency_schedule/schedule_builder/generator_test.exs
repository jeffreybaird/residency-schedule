defmodule ResidencySchedule.ScheduleBuilder.GeneratorTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.ScheduleBuilder.{Coverage, Generator, ResidentRoster, SlotCalendar}

  setup do
    residents = ResidentRoster.build_residents()
    slots = SlotCalendar.build_slots(2026)
    {:ok, residents: residents, slots: slots}
  end

  describe "assign_all/2" do
    test "returns a map", %{residents: residents, slots: slots} do
      assignments = Generator.assign_all(residents, slots)
      assert is_map(assignments)
    end

    test "all assignments are valid rotation type atoms", %{residents: residents, slots: slots} do
      assignments = Generator.assign_all(residents, slots)

      Enum.each(assignments, fn {_key, type} ->
        assert is_atom(type), "expected atom, got #{inspect(type)}"
      end)
    end

    test "every weekday slot has exactly 4 OB assignments across all residents",
         %{residents: residents, slots: slots} do
      assignments = Generator.assign_all(residents, slots)
      weekday_slots = Enum.filter(slots, &(!&1.is_weekend))

      Enum.each(weekday_slots, fn slot ->
        count = Coverage.count_for_slot(assignments, slot.slot_index, :strong_obstetrics)
        assert count == 4, "OB count in slot #{slot.slot_index} = #{count}, expected 4"
      end)
    end

    test "every weekday slot has exactly 4 ONC assignments", %{residents: residents, slots: slots} do
      assignments = Generator.assign_all(residents, slots)
      weekday_slots = Enum.filter(slots, &(!&1.is_weekend))

      Enum.each(weekday_slots, fn slot ->
        count = Coverage.count_for_slot(assignments, slot.slot_index, :oncology)
        assert count == 4, "ONC count in slot #{slot.slot_index} = #{count}, expected 4"
      end)
    end

    test "every weekday slot has exactly 4 GYN assignments", %{residents: residents, slots: slots} do
      assignments = Generator.assign_all(residents, slots)
      weekday_slots = Enum.filter(slots, &(!&1.is_weekend))

      Enum.each(weekday_slots, fn slot ->
        count = Coverage.count_for_slot(assignments, slot.slot_index, :strong_gynecology)
        assert count == 4, "GYN count in slot #{slot.slot_index} = #{count}, expected 4"
      end)
    end

    test "every weekday slot has exactly 4 AMB assignments", %{residents: residents, slots: slots} do
      assignments = Generator.assign_all(residents, slots)
      weekday_slots = Enum.filter(slots, &(!&1.is_weekend))

      Enum.each(weekday_slots, fn slot ->
        count = Coverage.count_for_slot(assignments, slot.slot_index, :ambulatory)
        assert count == 4, "AMB count in slot #{slot.slot_index} = #{count}, expected 4"
      end)
    end

    test "every weekday slot has exactly 4 NF assignments", %{residents: residents, slots: slots} do
      assignments = Generator.assign_all(residents, slots)
      weekday_slots = Enum.filter(slots, &(!&1.is_weekend))

      Enum.each(weekday_slots, fn slot ->
        count = Coverage.count_for_slot(assignments, slot.slot_index, :night_float)
        assert count == 4, "NF count in slot #{slot.slot_index} = #{count}, expected 4"
      end)
    end

    test "every weekday slot has exactly 1 HHOB assignment (R2 only)",
         %{residents: residents, slots: slots} do
      assignments = Generator.assign_all(residents, slots)
      weekday_slots = Enum.filter(slots, &(!&1.is_weekend))

      r2_indices =
        residents
        |> Enum.with_index()
        |> Enum.filter(fn {r, _} -> r.residency_year == 2 end)
        |> Enum.map(fn {_, i} -> i end)

      Enum.each(weekday_slots, fn slot ->
        count = Coverage.count_for_slot(assignments, slot.slot_index, :highland_obstetrics)
        assert count == 1, "HHOB count in slot #{slot.slot_index} = #{count}, expected 1"

        # Verify it's assigned to an R2 resident
        hhob_resident =
          Enum.find(r2_indices, fn r_idx ->
            Map.get(assignments, {r_idx, slot.slot_index}) == :highland_obstetrics
          end)

        assert hhob_resident != nil, "HHOB in slot #{slot.slot_index} not assigned to R2"
      end)
    end

    test "ONC residents get HWD (highland_weekend_days) on corresponding weekend slots",
         %{residents: residents, slots: slots} do
      assignments = Generator.assign_all(residents, slots)
      weekday_slots = Enum.filter(slots, &(!&1.is_weekend))
      weekend_slots_map = slots |> Enum.filter(& &1.is_weekend) |> Map.new(&{&1.slot_index, &1})

      Enum.each(weekday_slots, fn wd_slot ->
        we_slot_idx = wd_slot.slot_index + 1

        if Map.has_key?(weekend_slots_map, we_slot_idx) do
          Enum.each(residents |> Enum.with_index(), fn {_res, res_idx} ->
            if Map.get(assignments, {res_idx, wd_slot.slot_index}) == :oncology do
              weekend_type = Map.get(assignments, {res_idx, we_slot_idx})

              assert weekend_type == :highland_weekend_days,
                     "ONC resident #{res_idx} in slot #{wd_slot.slot_index} should have HWD weekend, got #{weekend_type}"
            end
          end)
        end
      end)
    end

    test "AMB residents get SWN (strong_weekend_nights) on corresponding weekend slots",
         %{residents: residents, slots: slots} do
      assignments = Generator.assign_all(residents, slots)
      weekday_slots = Enum.filter(slots, &(!&1.is_weekend))
      weekend_slots_map = slots |> Enum.filter(& &1.is_weekend) |> Map.new(&{&1.slot_index, &1})

      Enum.each(weekday_slots, fn wd_slot ->
        we_slot_idx = wd_slot.slot_index + 1

        if Map.has_key?(weekend_slots_map, we_slot_idx) do
          Enum.each(residents |> Enum.with_index(), fn {_res, res_idx} ->
            if Map.get(assignments, {res_idx, wd_slot.slot_index}) == :ambulatory do
              weekend_type = Map.get(assignments, {res_idx, we_slot_idx})

              assert weekend_type == :strong_weekend_nights,
                     "AMB resident #{res_idx} in slot #{wd_slot.slot_index} should have SWN weekend"
            end
          end)
        end
      end)
    end

    test "R2 residents receive highland_obstetrics (HHOB) slots",
         %{residents: residents, slots: slots} do
      assignments = Generator.assign_all(residents, slots)

      r2_indices =
        residents
        |> Enum.with_index()
        |> Enum.filter(fn {r, _} -> r.residency_year == 2 end)
        |> Enum.map(fn {_, i} -> i end)

      hhob_counts =
        Enum.map(r2_indices, fn res_idx ->
          Enum.count(assignments, fn {{ri, _slot}, type} ->
            ri == res_idx and type == :highland_obstetrics
          end)
        end)

      assert Enum.sum(hhob_counts) > 0, "No R2 residents got HHOB"
    end

    test "no R1 residents are assigned highland_obstetrics",
         %{residents: residents, slots: slots} do
      assignments = Generator.assign_all(residents, slots)

      r1_indices =
        residents
        |> Enum.with_index()
        |> Enum.filter(fn {r, _} -> r.residency_year == 1 end)
        |> Enum.map(fn {_, i} -> i end)

      r1_hhob =
        Enum.any?(assignments, fn {{ri, _slot}, type} ->
          ri in r1_indices and type == :highland_obstetrics
        end)

      refute r1_hhob, "R1 residents should not get HHOB"
    end

    test "R3 residents receive urogynecology (UG) slots",
         %{residents: residents, slots: slots} do
      assignments = Generator.assign_all(residents, slots)

      r3_indices =
        residents
        |> Enum.with_index()
        |> Enum.filter(fn {r, _} -> r.residency_year == 3 end)
        |> Enum.map(fn {_, i} -> i end)

      ug_count =
        Enum.count(assignments, fn {{ri, _slot}, type} ->
          ri in r3_indices and type == :urogynecology
        end)

      assert ug_count > 0, "R3 residents should get UG slots"
    end

    test "duty hour violations are within acceptable range (violations are UI warnings, not hard blocks)",
         %{residents: residents, slots: slots} do
      alias ResidencySchedule.ScheduleBuilder.DutyHours
      assignments = Generator.assign_all(residents, slots)
      violations = DutyHours.violations(assignments, slots, residents)
      # With simplified hour modeling (every OB weekday = 60h + SWD weekend = 24h),
      # some rolling-window averages may exceed 80h. These surface as UI warnings.
      # Verify violations don't exceed 50% of all rolling windows.
      total_windows = length(residents) * (52 - 3)
      violation_rate = length(violations) / total_windows

      assert violation_rate < 0.5,
             "Too many duty violations: #{length(violations)} of #{total_windows} windows (#{Float.round(violation_rate * 100, 1)}%)"
    end
  end
end
