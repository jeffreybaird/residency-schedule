defmodule ResidencySchedule.ScheduleBuilder.IntegrationTest do
  use ResidencySchedule.DataCase

  alias ResidencySchedule.ScheduleBuilder
  alias ResidencySchedule.Schedules

  describe "generate/1" do
    test "returns {:ok, state} with non-empty assignments" do
      assert {:ok, state} = ScheduleBuilder.generate(2030)
      assert state.academic_year == 2030
      assert length(state.residents) == 32
      assert map_size(state.assignments) > 0
    end

    test "generated state has slots covering the academic year" do
      {:ok, state} = ScheduleBuilder.generate(2030)
      first_slot = Enum.min_by(state.slots, & &1.slot_index)
      assert first_slot.start_date.year >= 2030
      assert first_slot.start_date.month >= 6
    end
  end

  describe "set_rotation/4" do
    test "updates a single cell and returns new state" do
      {:ok, state} = ScheduleBuilder.generate(2030)
      updated = ScheduleBuilder.set_rotation(state, 0, 0, :vacation)
      assert Map.get(updated.assignments, {0, 0}) == :vacation
    end

    test "does not mutate the original state" do
      {:ok, state} = ScheduleBuilder.generate(2030)
      original_assignment = Map.get(state.assignments, {0, 0})
      _updated = ScheduleBuilder.set_rotation(state, 0, 0, :vacation)
      assert Map.get(state.assignments, {0, 0}) == original_assignment
    end
  end

  describe "save/1 → DB" do
    test "persists the generated schedule and makes it retrievable" do
      {:ok, state} = ScheduleBuilder.generate(2029)
      assert {:ok, result} = ScheduleBuilder.save(state)
      assert result.residents == 32
      assert result.rotations > 0

      schedule = Schedules.get_schedule!(result.schedule_id)
      assert schedule.academic_year == 2029
      assert schedule.label == Schedules.academic_year_label(2029)
    end

    test "saving twice with the same year replaces data without duplication" do
      {:ok, state} = ScheduleBuilder.generate(2028)
      {:ok, first} = ScheduleBuilder.save(state)
      {:ok, second} = ScheduleBuilder.save(state)
      assert first.residents == second.residents
      assert first.rotations == second.rotations
      assert first.schedule_id == second.schedule_id
    end
  end

  describe "load_from_schedule/1" do
    test "loads residents and assignments from an existing DB schedule" do
      result = seed_schedule()
      schedule = Schedules.get_schedule!(result.schedule_id)

      {:ok, state} = ScheduleBuilder.load_from_schedule(schedule.id)

      assert state.academic_year == schedule.academic_year
      assert length(state.residents) > 0
      assert map_size(state.assignments) > 0
    end

    test "loaded state has 100 slots for the correct academic year" do
      result = seed_schedule()
      schedule = Schedules.get_schedule!(result.schedule_id)

      {:ok, state} = ScheduleBuilder.load_from_schedule(schedule.id)

      assert length(state.slots) == 100
    end
  end

  describe "resolve_violations/1" do
    test "returns a state with duty_warnings count <= original" do
      {:ok, state} = ScheduleBuilder.generate(2031)
      resolved = ScheduleBuilder.resolve_violations(state)
      assert length(resolved.duty_warnings) <= length(state.duty_warnings)
    end

    test "returns state unchanged when there are no duty violations" do
      state = %{
        academic_year: 2031,
        residents: [%{residency_year: 1, position_code: "R1-1", schedule_number: 1, name: "R1-1"}],
        slots: [%{slot_index: 0, start_date: ~D[2031-06-30], end_date: ~D[2031-07-04], is_weekend: false}],
        assignments: %{{0, 0} => :vacation},
        duty_warnings: [],
        coverage_warnings: []
      }
      resolved = ScheduleBuilder.resolve_violations(state)
      assert resolved.assignments == state.assignments
    end
  end

  describe "rename_resident/3" do
    test "updates resident name in builder state" do
      {:ok, state} = ScheduleBuilder.generate(2030)
      updated = ScheduleBuilder.rename_resident(state, 0, "Alice")
      assert hd(updated.residents).name == "Alice"
    end
  end

  describe "carry-over names (generate with prior year)" do
    test "R2–R4 residents carry names forward from prior year schedule" do
      {:ok, state_2029} = ScheduleBuilder.generate(2029)
      # Rename some residents and save
      state_with_names =
        state_2029.residents
        |> Enum.with_index()
        |> Enum.reduce(state_2029, fn {resident, idx}, acc ->
          label = "Person-#{resident.residency_year}-#{resident.schedule_number}"
          ScheduleBuilder.rename_resident(acc, idx, label)
        end)
      {:ok, _} = ScheduleBuilder.save(state_with_names)

      # Generate 2030 — R2s should have names from 2029's R1s, etc.
      {:ok, state_2030} = ScheduleBuilder.generate(2030)
      r2s = Enum.filter(state_2030.residents, & &1.residency_year == 2)
      # Each R2 in 2030 should have name of matching R1 from 2029
      Enum.each(r2s, fn r ->
        expected = "Person-1-#{r.schedule_number}"
        assert r.name == expected
      end)
    end

    test "R4s from prior year are not carried into the new year (new R1 placeholders remain)" do
      {:ok, state_2029} = ScheduleBuilder.generate(2029)
      # Name R4s explicitly
      state_with_r4_names =
        state_2029.residents
        |> Enum.with_index()
        |> Enum.reduce(state_2029, fn {resident, idx}, acc ->
          if resident.residency_year == 4 do
            ScheduleBuilder.rename_resident(acc, idx, "Graduate-#{resident.schedule_number}")
          else
            acc
          end
        end)
      {:ok, _} = ScheduleBuilder.save(state_with_r4_names)

      {:ok, state_2030} = ScheduleBuilder.generate(2030)
      r1s = Enum.filter(state_2030.residents, & &1.residency_year == 1)
      # R1 names should be placeholder codes, not graduate names
      Enum.each(r1s, fn r ->
        refute String.starts_with?(r.name, "Graduate-")
      end)
    end

    test "generate with no prior year returns placeholder names" do
      {:ok, state} = ScheduleBuilder.generate(2099)
      r1 = Enum.find(state.residents, & &1.residency_year == 1 and &1.schedule_number == 1)
      assert r1.name == "R1-1"
    end
  end

  describe "prior_year_names_for_level/2" do
    test "returns empty list when no prior year schedule exists" do
      names = ScheduleBuilder.prior_year_names_for_level(2099, 1)
      assert names == []
    end

    test "returns R1 names from prior year's R1 residents (year level 0 doesn't exist, so empty)" do
      {:ok, state_2029} = ScheduleBuilder.generate(2029)
      state_named =
        state_2029.residents
        |> Enum.with_index()
        |> Enum.reduce(state_2029, fn {resident, idx}, acc ->
          if resident.residency_year == 1 do
            ScheduleBuilder.rename_resident(acc, idx, "Incoming-#{resident.schedule_number}")
          else
            acc
          end
        end)
      {:ok, _} = ScheduleBuilder.save(state_named)

      # R1 names for year 2030 come from R1s of 2029 (residency_year - 1 == 0, none)
      # Actually prior_year_names_for_level filters by residency_year - 1 = 0, which is empty
      names = ScheduleBuilder.prior_year_names_for_level(2030, 1)
      assert names == []
    end

    test "returns R2 names from prior year when prior schedule has R2 residents" do
      {:ok, state_2029} = ScheduleBuilder.generate(2029)
      state_named =
        state_2029.residents
        |> Enum.with_index()
        |> Enum.reduce(state_2029, fn {resident, idx}, acc ->
          if resident.residency_year == 2 do
            ScheduleBuilder.rename_resident(acc, idx, "R2-Named-#{resident.schedule_number}")
          else
            acc
          end
        end)
      {:ok, _} = ScheduleBuilder.save(state_named)

      # R3 names for 2030 come from R2s of 2029
      names = ScheduleBuilder.prior_year_names_for_level(2030, 3)
      assert length(names) == 8
      Enum.each(names, fn name -> assert String.starts_with?(name, "R2-Named-") end)
    end
  end

  describe "valid_rotations_for_year/1" do
    test "R1 does not include :unknown or :highland_obstetrics" do
      types = ScheduleBuilder.valid_rotations_for_year(1)
      refute :unknown in types
      refute :highland_obstetrics in types
    end

    test "R2 includes :rei" do
      types = ScheduleBuilder.valid_rotations_for_year(2)
      assert :rei in types
    end
  end
end
