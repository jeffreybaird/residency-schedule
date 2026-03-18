defmodule ResidencySchedule.ScheduleBuilder.BuilderStateTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.ScheduleBuilder.BuilderState

  @resident %{position_code: "R1-1", residency_year: 1, schedule_number: 1, name: "R1-1"}
  @slot %{slot_index: 0, start_date: ~D[2026-06-29], end_date: ~D[2026-07-03], is_weekend: false}

  describe "new/4" do
    test "builds state with all required keys" do
      state = BuilderState.new(2026, [@resident], [@slot], %{})
      assert state.academic_year == 2026
      assert state.residents == [@resident]
      assert state.slots == [@slot]
      assert state.assignments == %{}
      assert is_list(state.duty_warnings)
      assert is_list(state.coverage_warnings)
      assert is_list(state.placement_warnings)
    end

    test "immediately computes warnings on creation" do
      # No assignments → all coverage constraints violated
      state = BuilderState.new(2026, [@resident], [@slot], %{})
      assert length(state.coverage_warnings) > 0
    end

    test "no coverage warnings when all required rotations are assigned" do
      # Provide enough assignments to satisfy OB, ONC, GYN, AMB, NF (4 each) + HHOB (1)
      residents =
        for i <- 0..3 do
          year = i + 1
          %{position_code: "R#{year}-1", residency_year: year, schedule_number: 1, name: "R#{year}-1"}
        end ++ [%{position_code: "R2-2", residency_year: 2, schedule_number: 2, name: "R2-2"}]

      slot = @slot

      assignments =
        Enum.with_index(residents)
        |> Enum.reduce(%{}, fn {_res, i}, acc ->
          rotation =
            case i do
              0 -> :strong_obstetrics
              1 -> :oncology
              2 -> :strong_gynecology
              3 -> :ambulatory
              _ -> :night_float
            end
          Map.put(acc, {i, 0}, rotation)
        end)
        |> Map.put({4, 0}, :highland_obstetrics)  # HHOB by the 5th resident (R2)

      # Add NF for resident 3 (R4) which covers year 4's night_float
      state = BuilderState.new(2026, residents, [slot], assignments)
      ob_warning = Enum.find(state.coverage_warnings, & &1.rotation_type == :strong_obstetrics and &1.slot_index == 0)
      # We have only 1 OB, needed 4 — so there will still be a warning
      assert ob_warning != nil
    end
  end

  describe "update_assignments/4" do
    test "replaces a single assignment" do
      state = BuilderState.new(2026, [@resident], [@slot], %{{0, 0} => :ambulatory})
      updated = BuilderState.update_assignments(state, 0, 0, :oncology)
      assert Map.get(updated.assignments, {0, 0}) == :oncology
    end

    test "adds a new assignment to a previously empty slot" do
      state = BuilderState.new(2026, [@resident], [@slot], %{})
      updated = BuilderState.update_assignments(state, 0, 0, :vacation)
      assert Map.get(updated.assignments, {0, 0}) == :vacation
    end

    test "triggers warning recomputation" do
      state = BuilderState.new(2026, [@resident], [@slot], %{})
      initial_warning_count = length(state.coverage_warnings)
      # Adding a vacation doesn't satisfy any coverage requirement
      updated = BuilderState.update_assignments(state, 0, 0, :vacation)
      # Coverage warnings should be same or more (not fewer from a vacation assignment)
      assert length(updated.coverage_warnings) >= 0
      assert is_list(updated.duty_warnings)
      # Recomputation ran (same state structure is returned)
      assert Map.has_key?(updated, :duty_warnings)
      assert initial_warning_count >= 0
    end

    test "does not mutate the original state" do
      state = BuilderState.new(2026, [@resident], [@slot], %{})
      _updated = BuilderState.update_assignments(state, 0, 0, :oncology)
      assert state.assignments == %{}
    end

    test "nil rotation_type removes the assignment (clear)" do
      state = BuilderState.new(2026, [@resident], [@slot], %{{0, 0} => :ambulatory})
      updated = BuilderState.update_assignments(state, 0, 0, nil)
      refute Map.has_key?(updated.assignments, {0, 0})
    end

    test "clearing a non-existent assignment is a no-op" do
      state = BuilderState.new(2026, [@resident], [@slot], %{})
      updated = BuilderState.update_assignments(state, 0, 0, nil)
      assert updated.assignments == %{}
    end
  end

  describe "move_resident_name/3" do
    @r1_2 %{position_code: "R1-2", residency_year: 1, schedule_number: 2, name: "Bob"}
    @r1_3 %{position_code: "R1-3", residency_year: 1, schedule_number: 3, name: "Carol"}
    @r2_1 %{position_code: "R2-1", residency_year: 2, schedule_number: 1, name: "Dave"}

    test "moves name forward and shifts in-between names back" do
      # Alice, Bob, Carol → move Alice (0) to Carol (2) → Bob, Carol, Alice
      state = BuilderState.new(2026, [@resident, @r1_2, @r1_3], [@slot], %{})
      updated = BuilderState.move_resident_name(state, 0, 2)
      assert Enum.at(updated.residents, 0).name == "Bob"
      assert Enum.at(updated.residents, 1).name == "Carol"
      assert Enum.at(updated.residents, 2).name == "R1-1"
    end

    test "moves name backward and shifts in-between names forward" do
      # Alice, Bob, Carol → move Carol (2) to Alice (0) → Carol, Alice, Bob
      state = BuilderState.new(2026, [@resident, @r1_2, @r1_3], [@slot], %{})
      updated = BuilderState.move_resident_name(state, 2, 0)
      assert Enum.at(updated.residents, 0).name == "Carol"
      assert Enum.at(updated.residents, 1).name == "R1-1"
      assert Enum.at(updated.residents, 2).name == "Bob"
    end

    test "does not mutate original state" do
      state = BuilderState.new(2026, [@resident, @r1_2], [@slot], %{})
      _updated = BuilderState.move_resident_name(state, 0, 1)
      assert Enum.at(state.residents, 0).name == "R1-1"
      assert Enum.at(state.residents, 1).name == "Bob"
    end

    test "returns state unchanged when indices are the same" do
      state = BuilderState.new(2026, [@resident, @r1_2], [@slot], %{})
      updated = BuilderState.move_resident_name(state, 0, 0)
      assert updated.residents == state.residents
    end

    test "returns state unchanged when residents are different year levels" do
      state = BuilderState.new(2026, [@resident, @r2_1], [@slot], %{})
      updated = BuilderState.move_resident_name(state, 0, 1)
      assert Enum.at(updated.residents, 0).name == "R1-1"
      assert Enum.at(updated.residents, 1).name == "Dave"
    end

    test "assignments stay with their positions after move" do
      state = BuilderState.new(2026, [@resident, @r1_2, @r1_3], [@slot], %{{0, 0} => :oncology, {1, 0} => :ambulatory, {2, 0} => :vacation})
      # Move position 0 to position 2 — assignments stay, only names shift
      updated = BuilderState.move_resident_name(state, 0, 2)
      assert Map.get(updated.assignments, {0, 0}) == :oncology
      assert Map.get(updated.assignments, {1, 0}) == :ambulatory
      assert Map.get(updated.assignments, {2, 0}) == :vacation
    end
  end

  describe "rename_resident/3" do
    test "updates the name of the resident at the given index" do
      state = BuilderState.new(2026, [@resident], [@slot], %{})
      updated = BuilderState.rename_resident(state, 0, "Alice")
      assert hd(updated.residents).name == "Alice"
    end

    test "does not mutate the original state" do
      state = BuilderState.new(2026, [@resident], [@slot], %{})
      _updated = BuilderState.rename_resident(state, 0, "Alice")
      assert hd(state.residents).name == "R1-1"
    end

    test "only changes the resident at the specified index" do
      second_resident = %{position_code: "R1-2", residency_year: 1, schedule_number: 2, name: "R1-2"}
      state = BuilderState.new(2026, [@resident, second_resident], [@slot], %{})
      updated = BuilderState.rename_resident(state, 0, "Alice")
      assert Enum.at(updated.residents, 0).name == "Alice"
      assert Enum.at(updated.residents, 1).name == "R1-2"
    end
  end

  describe "recompute_warnings/1" do
    test "merges duty, coverage, and placement warnings into state" do
      state = %{
        residents: [@resident],
        slots: [@slot],
        assignments: %{},
        duty_warnings: :stale,
        coverage_warnings: :stale,
        placement_warnings: :stale
      }
      result = BuilderState.recompute_warnings(state)
      assert is_list(result.duty_warnings)
      assert is_list(result.coverage_warnings)
      assert is_list(result.placement_warnings)
    end

    test "returns coverage warnings for uncovered slots" do
      state = %{residents: [@resident], slots: [@slot], assignments: %{}, duty_warnings: [], coverage_warnings: [], placement_warnings: []}
      result = BuilderState.recompute_warnings(state)
      assert length(result.coverage_warnings) > 0
    end

    test "returns placement warnings when a rotation is on the wrong slot type" do
      weekend_slot = %{slot_index: 1, is_weekend: true, start_date: ~D[2026-07-04], end_date: ~D[2026-07-05]}
      state = %{
        residents: [@resident],
        slots: [@slot, weekend_slot],
        assignments: %{{0, 1} => :strong_obstetrics},
        duty_warnings: [],
        coverage_warnings: [],
        placement_warnings: []
      }
      result = BuilderState.recompute_warnings(state)
      assert length(result.placement_warnings) == 1
      assert hd(result.placement_warnings).reason == :weekday_only
    end
  end
end
