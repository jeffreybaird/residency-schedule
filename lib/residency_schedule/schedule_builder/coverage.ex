defmodule ResidencySchedule.ScheduleBuilder.Coverage do
  @moduledoc """
  Validates service coverage constraints and slot-type placement rules.

  Hard coverage requirements that must be met every weekday slot:
  - OB, ONC, GYN, AMB, NF: exactly 4 (one per residency year)
  - HHOB: exactly 1 (R2 only)

  Weekend requirements:
  - SWD, SWN: exactly 4

  Slot-type placement rules:
  - Weekday-only rotations (clinical) must not appear on weekend or FLOAT slots.
  - Weekend-only rotations (SWD/SWN/HWD/HWN) must not appear on weekday or FLOAT slots.
  - FLOAT slots must only have :float assigned.
  """

  @weekday_only_rotations ~w(
    strong_obstetrics
    oncology
    strong_gynecology
    ambulatory
    night_float
    highland_obstetrics
    highland_gynecology
    highland_night_float
    rei
    urogynecology
    elective
    swing
    ultrasound
    vacation
  )a

  @weekend_only_rotations ~w(
    strong_weekend_days
    strong_weekend_nights
    highland_weekend_days
    highland_weekend_nights
  )a

  @required_weekday %{
    strong_obstetrics: 4,
    oncology: 4,
    strong_gynecology: 4,
    ambulatory: 4,
    night_float: 4,
    highland_obstetrics: 1
  }

  @required_weekend %{
    strong_weekend_days: 4,
    strong_weekend_nights: 4
  }

  @doc """
  Returns the map of required coverage counts for weekday rotations.

      iex> coverage = ResidencySchedule.ScheduleBuilder.Coverage.required_coverage()
      iex> Map.fetch!(coverage, :strong_obstetrics)
      4
      iex> Map.fetch!(coverage, :highland_obstetrics)
      1
  """
  def required_coverage, do: Map.merge(@required_weekday, @required_weekend)

  @doc """
  Counts how many residents are assigned a given rotation type in a given slot.

      iex> assignments = %{{0, 2} => :strong_obstetrics, {1, 2} => :strong_obstetrics, {2, 2} => :oncology}
      iex> ResidencySchedule.ScheduleBuilder.Coverage.count_for_slot(assignments, 2, :strong_obstetrics)
      2
  """
  def count_for_slot(assignments, slot_index, rotation_type) do
    assignments
    |> Enum.count(fn {{_res, slot}, type} ->
      slot == slot_index and type == rotation_type
    end)
  end

  @doc """
  Returns all coverage shortfall warnings for a set of assignments.

  Only checks weekday slots for weekday constraints and weekend slots for
  weekend constraints.

  Returns a list of warning maps, each with:
  - `slot_index`
  - `rotation_type`
  - `actual` — count found
  - `required` — count required

      iex> slots = [%{slot_index: 0, is_weekend: false}]
      iex> assignments = %{{0, 0} => :strong_obstetrics}
      iex> residents = for i <- 0..3, do: %{residency_year: rem(i, 4) + 1}
      iex> warnings = ResidencySchedule.ScheduleBuilder.Coverage.coverage_warnings(assignments, slots, residents)
      iex> Enum.any?(warnings, & &1.rotation_type == :strong_obstetrics)
      true

      iex> float_slots = [%{slot_index: 0, is_weekend: false}]
      iex> float_assignments = %{{0, 0} => :float, {1, 0} => :float, {2, 0} => :float, {3, 0} => :float}
      iex> residents = for i <- 0..3, do: %{residency_year: rem(i, 4) + 1}
      iex> ResidencySchedule.ScheduleBuilder.Coverage.coverage_warnings(float_assignments, float_slots, residents)
      []
  """
  def coverage_warnings(assignments, slots, _residents) do
    float_slots = float_slot_indices(assignments)

    weekday_slots =
      slots
      |> Enum.filter(&(!&1.is_weekend))
      |> Enum.reject(&MapSet.member?(float_slots, &1.slot_index))

    weekend_slots =
      slots
      |> Enum.filter(& &1.is_weekend)
      |> Enum.reject(&MapSet.member?(float_slots, &1.slot_index))

    check_slots(assignments, weekday_slots, @required_weekday) ++
      check_slots(assignments, weekend_slots, @required_weekend)
  end

  @doc """
  Returns placement warnings for assignments where a rotation is on the wrong slot type.

  Weekday-only rotations (OB, ONC, GYN, AMB, NF, etc.) must not appear on weekend
  or FLOAT slots. Weekend-only rotations (SWD, SWN, HWD, HWN) must not appear on
  weekday or FLOAT slots. FLOAT slots must only have :float assigned.

  Returns a list of warning maps, each with:
  - `resident_index`
  - `slot_index`
  - `rotation_type`
  - `reason` — `:weekday_only`, `:weekend_only`, or `:float_slot_only`

      iex> slots = [%{slot_index: 1, is_weekend: true, start_date: ~D[2026-07-04], end_date: ~D[2026-07-05]}]
      iex> assignments = %{{0, 1} => :strong_obstetrics}
      iex> [warning] = ResidencySchedule.ScheduleBuilder.Coverage.placement_warnings(assignments, slots)
      iex> warning.reason
      :weekday_only
  """
  def placement_warnings(assignments, slots) do
    slot_map = Map.new(slots, &{&1.slot_index, &1})

    assignments
    |> Enum.flat_map(fn {{res_idx, slot_idx}, rotation_type} ->
      case Map.get(slot_map, slot_idx) do
        nil -> []
        slot -> check_placement(res_idx, slot_idx, rotation_type, slot)
      end
    end)
    |> Enum.sort_by(&{&1.slot_index, &1.resident_index})
  end

  # --- Private ---

  defp check_placement(res_idx, slot_idx, rotation_type, slot) do
    cond do
      float_slot?(slot) and rotation_type != :float ->
        [
          %{
            resident_index: res_idx,
            slot_index: slot_idx,
            rotation_type: rotation_type,
            reason: :float_slot_only
          }
        ]

      not slot.is_weekend and not float_slot?(slot) and rotation_type in @weekend_only_rotations ->
        [
          %{
            resident_index: res_idx,
            slot_index: slot_idx,
            rotation_type: rotation_type,
            reason: :weekend_only
          }
        ]

      slot.is_weekend and rotation_type in @weekday_only_rotations ->
        [
          %{
            resident_index: res_idx,
            slot_index: slot_idx,
            rotation_type: rotation_type,
            reason: :weekday_only
          }
        ]

      true ->
        []
    end
  end

  defp float_slot?(slot) do
    not slot.is_weekend and Date.diff(slot.end_date, slot.start_date) == 6
  end

  defp float_slot_indices(assignments) do
    assignments
    |> Enum.filter(fn {_key, rotation} -> rotation == :float end)
    |> MapSet.new(fn {{_res, slot_idx}, _} -> slot_idx end)
  end

  defp check_slots(assignments, slots, requirements) do
    Enum.flat_map(slots, fn slot ->
      Enum.flat_map(requirements, fn {rotation_type, required_count} ->
        actual = count_for_slot(assignments, slot.slot_index, rotation_type)

        coverage_shortfall(slot, rotation_type, actual, required_count)
      end)
    end)
  end

  defp coverage_shortfall(slot, rotation_type, actual, required_count) do
    if actual < required_count do
      [
        %{
          slot_index: slot.slot_index,
          rotation_type: rotation_type,
          actual: actual,
          required: required_count
        }
      ]
    else
      []
    end
  end
end
