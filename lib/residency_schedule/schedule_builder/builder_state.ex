defmodule ResidencySchedule.ScheduleBuilder.BuilderState do
  @moduledoc """
  Constructs and manages the in-memory builder state map.

  The state is the single source of truth for the BuilderLive LiveView.
  All mutations return a new state with warnings recomputed.
  """

  alias ResidencySchedule.ScheduleBuilder.{DutyHours, Coverage}

  @doc """
  Builds the initial builder state from generated components.

  Returns a map with all keys required by the BuilderLive socket.

      iex> state = ResidencySchedule.ScheduleBuilder.BuilderState.new(
      ...>   2026,
      ...>   [%{position_code: "R1-1", residency_year: 1, schedule_number: 1, name: "R1-1"}],
      ...>   [%{slot_index: 0, start_date: ~D[2026-06-29], end_date: ~D[2026-07-03], is_weekend: false}],
      ...>   %{{0, 0} => :ambulatory}
      ...> )
      iex> state.academic_year
      2026
      iex> is_map(state.assignments)
      true
  """
  def new(academic_year, residents, slots, assignments) do
    state = %{
      academic_year: academic_year,
      residents: residents,
      slots: slots,
      assignments: assignments,
      duty_warnings: [],
      coverage_warnings: [],
      placement_warnings: []
    }

    recompute_warnings(state)
  end

  @doc """
  Returns a new state with a single assignment updated and warnings recomputed.

      iex> state = ResidencySchedule.ScheduleBuilder.BuilderState.new(
      ...>   2026,
      ...>   [%{position_code: "R1-1", residency_year: 1, schedule_number: 1, name: "R1-1"}],
      ...>   [%{slot_index: 0, start_date: ~D[2026-06-29], end_date: ~D[2026-07-03], is_weekend: false}],
      ...>   %{}
      ...> )
      iex> updated = ResidencySchedule.ScheduleBuilder.BuilderState.update_assignments(state, 0, 0, :oncology)
      iex> Map.get(updated.assignments, {0, 0})
      :oncology
  """
  @doc """
  Returns a new state with the named resident's display name updated.

      iex> state = ResidencySchedule.ScheduleBuilder.BuilderState.new(
      ...>   2026,
      ...>   [%{position_code: "R1-1", residency_year: 1, schedule_number: 1, name: "R1-1"}],
      ...>   [%{slot_index: 0, start_date: ~D[2026-06-29], end_date: ~D[2026-07-03], is_weekend: false}],
      ...>   %{}
      ...> )
      iex> updated = ResidencySchedule.ScheduleBuilder.BuilderState.rename_resident(state, 0, "Alice")
      iex> hd(updated.residents).name
      "Alice"
  """
  def rename_resident(state, resident_index, name) do
    updated_residents =
      List.update_at(state.residents, resident_index, & %{&1 | name: name})

    %{state | residents: updated_residents}
  end

  @doc """
  Moves the display name at `from_idx` to `to_idx` within the same residency year,
  shifting all names in between. Rotation assignments stay in place — only names move.
  Returns state unchanged if indices are identical or residents are in different year levels.

      iex> state = ResidencySchedule.ScheduleBuilder.BuilderState.new(
      ...>   2026,
      ...>   [%{position_code: "R1-1", residency_year: 1, schedule_number: 1, name: "Alice"},
      ...>    %{position_code: "R1-2", residency_year: 1, schedule_number: 2, name: "Bob"},
      ...>    %{position_code: "R1-3", residency_year: 1, schedule_number: 3, name: "Carol"}],
      ...>   [%{slot_index: 0, start_date: ~D[2026-06-29], end_date: ~D[2026-07-03], is_weekend: false}],
      ...>   %{}
      ...> )
      iex> updated = ResidencySchedule.ScheduleBuilder.BuilderState.move_resident_name(state, 0, 2)
      iex> Enum.at(updated.residents, 0).name
      "Bob"
      iex> Enum.at(updated.residents, 2).name
      "Alice"
  """
  def move_resident_name(state, from_idx, to_idx) when from_idx == to_idx, do: state

  def move_resident_name(state, from_idx, to_idx) do
    res_from = Enum.at(state.residents, from_idx)
    res_to = Enum.at(state.residents, to_idx)

    if res_from.residency_year != res_to.residency_year do
      state
    else
      year = res_from.residency_year

      # Indices within the full list that belong to this residency year, in order
      year_indices =
        state.residents
        |> Enum.with_index()
        |> Enum.filter(fn {r, _} -> r.residency_year == year end)
        |> Enum.map(fn {_, i} -> i end)

      from_year_idx = Enum.find_index(year_indices, &(&1 == from_idx))
      to_year_idx = Enum.find_index(year_indices, &(&1 == to_idx))

      year_names = Enum.map(year_indices, fn i -> Enum.at(state.residents, i).name end)

      name_to_move = Enum.at(year_names, from_year_idx)

      new_year_names =
        year_names
        |> List.delete_at(from_year_idx)
        |> List.insert_at(to_year_idx, name_to_move)

      updated_residents =
        state.residents
        |> Enum.with_index()
        |> Enum.map(fn {res, i} ->
          case Enum.find_index(year_indices, &(&1 == i)) do
            nil -> res
            year_idx -> %{res | name: Enum.at(new_year_names, year_idx)}
          end
        end)

      %{state | residents: updated_residents}
    end
  end

  def update_assignments(state, resident_index, slot_index, nil) do
    updated_assignments = Map.delete(state.assignments, {resident_index, slot_index})
    %{state | assignments: updated_assignments}
    |> recompute_warnings()
  end

  def update_assignments(state, resident_index, slot_index, rotation_type) do
    updated_assignments = Map.put(state.assignments, {resident_index, slot_index}, rotation_type)
    %{state | assignments: updated_assignments}
    |> recompute_warnings()
  end

  @doc """
  Recomputes all duty and coverage warnings from current state.

      iex> state = %{
      ...>   residents: [%{residency_year: 1}],
      ...>   slots: [%{slot_index: 0, is_weekend: false, start_date: ~D[2026-06-29], end_date: ~D[2026-07-03]}],
      ...>   assignments: %{}
      ...> }
      iex> result = ResidencySchedule.ScheduleBuilder.BuilderState.recompute_warnings(state)
      iex> is_list(result.duty_warnings)
      true
      iex> is_list(result.coverage_warnings)
      true
      iex> is_list(result.placement_warnings)
      true
  """
  def recompute_warnings(state) do
    duty_warnings =
      DutyHours.violations(state.assignments, state.slots, state.residents)

    coverage_warnings =
      Coverage.coverage_warnings(state.assignments, state.slots, state.residents)

    placement_warnings =
      Coverage.placement_warnings(state.assignments, state.slots)

    %{state | duty_warnings: duty_warnings, coverage_warnings: coverage_warnings, placement_warnings: placement_warnings}
  end
end
