defmodule ResidencySchedule.ScheduleBuilder do
  @moduledoc """
  Public API for the Schedule Builder feature.

  All BuilderLive interactions go through this module. Internally delegates to
  `SlotCalendar`, `ResidentRoster`, `Generator`, `BuilderState`, `DutyHours`,
  and `Coverage`.

  The builder state is a pure in-memory map — no DB access until `save/1` or
  `load_from_schedule/1` is called.
  """

  alias ResidencySchedule.ScheduleBuilder.{
    BuilderState,
    Coverage,
    DutyHours,
    ResidentRoster,
    SlotCalendar,
    TemplateLoader
  }

  alias ResidencySchedule.Importer.{CsvParser, ScheduleImporter}
  alias ResidencySchedule.{Residents, Rotations, Schedules}

  @doc """
  Generates a new draft schedule for the given academic year using the
  2025–2026 rotation template as a baseline.

  Applies the template's rotation pattern (which position gets which rotation
  in which slot) to the correct calendar dates for the requested year.
  Returns `{:ok, builder_state}`.

      iex> {:ok, state} = ResidencySchedule.ScheduleBuilder.generate(2026)
      iex> state.academic_year
      2026
      iex> length(state.residents)
      32
  """
  def generate(academic_year) do
    pattern = TemplateLoader.load_pattern()
    residents = ResidentRoster.build_residents() |> carry_over_names(academic_year)
    slots = SlotCalendar.build_slots(academic_year)
    slot_set = MapSet.new(slots, & &1.slot_index)
    float_slots = SlotCalendar.float_slot_indices(academic_year, slots)

    template_assignments =
      residents
      |> Enum.with_index()
      |> Enum.flat_map(fn {resident, res_idx} ->
        resident.position_code
        |> then(&Map.get(pattern, &1, []))
        # Strip FLOAT from template — calendar-computed positions override it
        |> Enum.reject(fn {_slot_idx, rotation_type} -> rotation_type == :float end)
        |> Enum.flat_map(fn {slot_idx, rotation_type} ->
          template_assignment(res_idx, slot_idx, rotation_type, slot_set, float_slots)
        end)
      end)
      |> Map.new()

    float_assignments =
      residents
      |> Enum.with_index()
      |> Enum.flat_map(fn {_resident, res_idx} ->
        Enum.map(float_slots, fn slot_idx -> {{res_idx, slot_idx}, :float} end)
      end)
      |> Map.new()

    state =
      BuilderState.new(
        academic_year,
        residents,
        slots,
        Map.merge(template_assignments, float_assignments)
      )

    {:ok, state}
  end

  @doc """
  Loads an existing schedule from the database into builder state.

  Converts the DB residents and their rotations into the in-memory builder
  format. Legacy schedules use the annual slot calendar; date updates retain
  their literal date boundaries when loaded and saved.
  Returns `{:ok, builder_state}`. Date-updated schedules with overlapping shifts
  return `{:error, reason}` because the editor supports one assignment per cell.

  Exempt from doctest — hits the database.
  """
  def load_from_schedule(schedule_id) do
    schedule = Schedules.get_schedule!(schedule_id)
    db_residents = Residents.list_residents_for_schedule(schedule_id)
    builder_residents = Enum.map(db_residents, &resident_to_builder_map/1)

    rotations_by_resident =
      Map.new(db_residents, &{&1.id, Rotations.list_rotations_for_resident(&1.id)})

    literal_dates? =
      Enum.any?(rotations_by_resident, fn {_, rotations} ->
        indices = Enum.map(rotations, & &1.slot_index)
        Enum.any?(indices, &(&1 < 0)) or length(indices) != length(Enum.uniq(indices))
      end)

    if literal_dates? and
         Enum.any?(rotations_by_resident, fn {_, rotations} ->
           overlapping_rotations?(rotations)
         end) do
      {:error,
       "This schedule has overlapping shifts that the editor cannot represent safely. Use Update dates to change specific days."}
    else
      load_builder_state(
        schedule,
        db_residents,
        builder_residents,
        rotations_by_resident,
        literal_dates?
      )
    end
  end

  defp overlapping_rotations?(rotations) do
    rotations
    |> Enum.sort_by(&Date.to_gregorian_days(&1.start_date))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.any?(fn [first, second] -> Date.compare(first.end_date, second.start_date) != :lt end)
  end

  defp load_builder_state(
         schedule,
         db_residents,
         builder_residents,
         rotations_by_resident,
         literal_dates?
       ) do
    slots =
      if literal_dates?,
        do: literal_builder_slots(Map.values(rotations_by_resident) |> List.flatten()),
        else: SlotCalendar.build_slots(schedule.academic_year)

    slot_set = MapSet.new(slots, & &1.slot_index)

    assignments =
      db_residents
      |> Enum.with_index()
      |> Enum.flat_map(fn {resident, res_idx} ->
        rotations = Map.fetch!(rotations_by_resident, resident.id)

        if literal_dates?,
          do: dated_assignments(rotations, res_idx, slots),
          else: build_assignments_for_resident(rotations, res_idx, slot_set)
      end)
      |> Map.new()

    state =
      BuilderState.new(schedule.academic_year, builder_residents, slots, assignments)
      |> Map.put(:literal_dates?, literal_dates?)

    {:ok, state}
  end

  @doc """
  Iteratively resolves duty hour violations by replacing high-hour assignments
  with vacation slots, respecting coverage minimums.

  Processes each violation in turn, finding the highest-hour assignment in the
  offending window that can be safely removed (i.e. coverage remains at or above
  the required minimum). Repeats until no violations remain or no fixable
  assignment can be found.

      iex> {:ok, state} = ResidencySchedule.ScheduleBuilder.generate(2026)
      iex> resolved = ResidencySchedule.ScheduleBuilder.resolve_violations(state)
      iex> length(resolved.duty_warnings) <= length(state.duty_warnings)
      true
  """
  def resolve_violations(state) do
    resolve_loop(state, 300)
  end

  @doc """
  Updates a single cell in the builder state and recomputes warnings.

  Returns the updated state map.

      iex> {:ok, state} = ResidencySchedule.ScheduleBuilder.generate(2026)
      iex> updated = ResidencySchedule.ScheduleBuilder.set_rotation(state, 0, 0, :vacation)
      iex> Map.get(updated.assignments, {0, 0})
      :vacation
  """
  def set_rotation(state, resident_index, slot_index, rotation_type) do
    BuilderState.update_assignments(state, resident_index, slot_index, rotation_type)
  end

  @doc """
  Returns the list of rotation type atoms valid for a given residency year.

      iex> types = ResidencySchedule.ScheduleBuilder.valid_rotations_for_year(2)
      iex> :rei in types
      true
      iex> :urogynecology in types
      false
  """
  def valid_rotations_for_year(residency_year) do
    ResidentRoster.valid_rotations_for_year(residency_year)
  end

  @doc """
  Returns the rotation types valid for a given residency year and slot type.

  Delegates slot-type filtering to ResidentRoster. FLOAT slots return only [:float].
  Weekend slots exclude weekday-only rotations. Weekday slots exclude weekend-only.

      iex> slot = %{is_weekend: true, start_date: ~D[2026-07-04], end_date: ~D[2026-07-05]}
      iex> types = ResidencySchedule.ScheduleBuilder.valid_rotations_for_slot(1, slot)
      iex> :strong_weekend_days in types
      true
      iex> :ambulatory in types
      false
  """
  def valid_rotations_for_slot(residency_year, slot) do
    ResidentRoster.valid_rotations_for_slot(residency_year, slot)
  end

  @doc """
  Removes a resident's assignment for a slot, recomputing warnings.

  Equivalent to set_rotation with nil — the cell reverts to unassigned.

      iex> {:ok, state} = ResidencySchedule.ScheduleBuilder.generate(2031)
      iex> updated = ResidencySchedule.ScheduleBuilder.clear_rotation(state, 0, 0)
      iex> Map.has_key?(updated.assignments, {0, 0})
      false
  """
  def clear_rotation(state, resident_index, slot_index) do
    BuilderState.update_assignments(state, resident_index, slot_index, nil)
  end

  @doc """
  Saves the builder state as a real schedule in the database.

  Converts the in-memory assignments into `%CsvParser{}` structs and calls
  `ScheduleImporter.persist/1`. Returns `{:ok, result}` or `{:error, reason}`.

  Exempt from doctest — hits the database.
  """
  def save(state) do
    parsed_residents =
      state
      |> build_parsed_residents()
      |> preserve_literal_slot_markers(Map.get(state, :literal_dates?, false))

    case ScheduleImporter.persist(parsed_residents, state.academic_year) do
      {:ok, result} -> {:ok, result}
      {:error, reason} -> {:error, reason}
    end
  end

  # --- Private: violation resolution ---

  defp resolve_loop(state, 0), do: state

  defp resolve_loop(state, iters_left) do
    violations = DutyHours.violations(state.assignments, state.slots, state.residents)

    case find_fixable(violations, state) do
      nil ->
        state

      {res_idx, slot_idx} ->
        new_state = BuilderState.update_assignments(state, res_idx, slot_idx, :vacation)
        resolve_loop(new_state, iters_left - 1)
    end
  end

  defp find_fixable(violations, state) do
    Enum.find_value(violations, nil, fn violation ->
      window = SlotCalendar.slots_for_window(state.slots, violation.window_start_slot, 4)
      find_swappable_in_window(violation.resident_index, window, state)
    end)
  end

  defp find_swappable_in_window(res_idx, window_slots, state) do
    window_slots
    |> Enum.filter(fn slot ->
      rt = Map.get(state.assignments, {res_idx, slot.slot_index})
      rt != nil and DutyHours.hours_for_rotation(rt) > 0 and rt != :vacation
    end)
    |> Enum.sort_by(fn slot ->
      rt = Map.get(state.assignments, {res_idx, slot.slot_index})
      -DutyHours.slot_hours(rt, slot)
    end)
    |> Enum.find_value(nil, fn slot ->
      rt = Map.get(state.assignments, {res_idx, slot.slot_index})

      if can_swap_to_vacation?(rt, slot.slot_index, state) do
        {res_idx, slot.slot_index}
      else
        nil
      end
    end)
  end

  defp can_swap_to_vacation?(rotation_type, slot_index, state) do
    required = Coverage.required_coverage()

    case Map.get(required, rotation_type) do
      nil ->
        true

      min_count ->
        current = Coverage.count_for_slot(state.assignments, slot_index, rotation_type)
        current > min_count
    end
  end

  @doc """
  Updates the display name of a resident in builder state.

  The name change is reflected immediately and persists when `save/1` is called.

      iex> {:ok, state} = ResidencySchedule.ScheduleBuilder.generate(2031)
      iex> updated = ResidencySchedule.ScheduleBuilder.rename_resident(state, 0, "Alice")
      iex> hd(updated.residents).name
      "Alice"
  """
  def rename_resident(state, resident_index, name) do
    BuilderState.rename_resident(state, resident_index, name)
  end

  @doc """
  Moves the display name at `from_idx` to `to_idx` within the same year level,
  shifting all names in between. Rotation assignments stay in place — only the names
  move. No-op if the indices are the same or the residents belong to different year levels.

      iex> {:ok, state} = ResidencySchedule.ScheduleBuilder.generate(2031)
      iex> name_0 = Enum.at(state.residents, 0).name
      iex> name_1 = Enum.at(state.residents, 1).name
      iex> updated = ResidencySchedule.ScheduleBuilder.move_resident_name(state, 0, 1)
      iex> Enum.at(updated.residents, 0).name == name_1
      true
  """
  def move_resident_name(state, from_idx, to_idx) do
    BuilderState.move_resident_name(state, from_idx, to_idx)
  end

  @doc """
  Returns the list of prior-year resident names for a given year level, to
  support autocomplete when naming new residents.

  Queries the schedule for `academic_year - 1`. R1 names are from R1s of that
  year who graduated or are new; R2–R4 names are auto-populated so this list
  is primarily useful for R1 slots. Returns an empty list if no prior schedule.

  Exempt from doctest — hits the database.
  """
  def prior_year_names_for_level(academic_year, residency_year) do
    case Schedules.get_by_year(academic_year - 1) do
      nil ->
        []

      prior_schedule ->
        prior_schedule.id
        |> Residents.list_residents_for_schedule()
        |> Enum.filter(&(&1.residency_year == residency_year - 1))
        |> Enum.map(& &1.name)
        |> Enum.reject(&(&1 == "" or &1 == nil))
    end
  end

  # --- Private: name carry-over ---

  # When generating a new schedule, populate resident names from the prior year
  # by bumping each resident's year level up by one (R1→R2, R2→R3, R3→R4).
  # R4s graduate and are not carried over. New R1s keep placeholder names.
  defp carry_over_names(residents, academic_year) do
    case Schedules.get_by_year(academic_year - 1) do
      nil ->
        residents

      prior_schedule ->
        name_map = build_name_map(prior_schedule.id)

        Enum.map(residents, &apply_carried_name(&1, name_map))
    end
  end

  # Builds a map of {next_year_level, schedule_number} → name from the prior schedule.
  defp build_name_map(prior_schedule_id) do
    prior_schedule_id
    |> Residents.list_residents_for_schedule()
    |> Enum.reduce(%{}, fn r, acc ->
      next_year = r.residency_year + 1

      if next_year <= 4 do
        Map.put(acc, {next_year, r.schedule_number}, r.name)
      else
        acc
      end
    end)
  end

  # --- Private: load from DB helpers ---

  defp resident_to_builder_map(resident) do
    %{
      position_code: resident.position_code,
      residency_year: resident.residency_year,
      schedule_number: resident.schedule_number,
      name: resident.name
    }
  end

  defp literal_builder_slots(rotations) do
    rotations
    |> Rotations.date_slots()
    |> Enum.map(fn {index, start, finish} ->
      %{
        slot_index: index,
        start_date: start,
        end_date: finish,
        is_weekend: Date.day_of_week(start) in [6, 7] and Date.day_of_week(finish) in [6, 7]
      }
    end)
  end

  defp dated_assignments(rotations, resident_index, slots) do
    Enum.flat_map(slots, fn slot ->
      case Enum.find(
             rotations,
             &(Date.compare(&1.start_date, slot.start_date) != :gt and
                 Date.compare(&1.end_date, slot.start_date) != :lt)
           ) do
        nil ->
          []

        rotation ->
          [{{resident_index, slot.slot_index}, String.to_existing_atom(rotation.rotation_type)}]
      end
    end)
  end

  defp preserve_literal_slot_markers(parsed, false), do: parsed

  defp preserve_literal_slot_markers(parsed, true) do
    Enum.map(parsed, fn resident ->
      %{
        resident
        | rotations: Enum.map(resident.rotations, &%{&1 | slot_index: -&1.slot_index - 1})
      }
    end)
  end

  defp build_assignments_for_resident(rotations, res_idx, slot_set) do
    Enum.flat_map(rotations, fn rotation ->
      if rotation.slot_index in slot_set do
        rotation_atom = String.to_existing_atom(rotation.rotation_type)
        [{{res_idx, rotation.slot_index}, rotation_atom}]
      else
        []
      end
    end)
  end

  # --- Private: save helpers ---

  defp build_parsed_residents(%{residents: residents, slots: slots, assignments: assignments}) do
    slot_map = Map.new(slots, &{&1.slot_index, &1})

    residents
    |> Enum.with_index()
    |> Enum.map(fn {resident, res_idx} ->
      rotations = build_rotations_for_resident(res_idx, slot_map, assignments)

      %CsvParser{
        position_code: resident.position_code,
        residency_year: resident.residency_year,
        schedule_number: resident.schedule_number,
        name: resident.name,
        rotations: rotations
      }
    end)
  end

  defp build_rotations_for_resident(res_idx, slot_map, assignments) do
    assignments
    |> Enum.filter(fn {{ri, _slot_idx}, _type} -> ri == res_idx end)
    |> Enum.flat_map(fn {{_ri, slot_idx}, rotation_type} ->
      case Map.get(slot_map, slot_idx) do
        nil ->
          []

        slot ->
          [
            %{
              slot_index: slot_idx,
              start_date: slot.start_date,
              end_date: slot.end_date,
              rotation_type: rotation_type
            }
          ]
      end
    end)
    |> Enum.sort_by(& &1.slot_index)
  end

  defp template_assignment(resident_index, slot_index, rotation_type, slots, float_slots) do
    if slot_index in slots and slot_index not in float_slots,
      do: [{{resident_index, slot_index}, rotation_type}],
      else: []
  end

  defp apply_carried_name(resident, name_map) do
    bumped_name = Map.get(name_map, {resident.residency_year, resident.schedule_number})
    if bumped_name, do: %{resident | name: bumped_name}, else: resident
  end
end
