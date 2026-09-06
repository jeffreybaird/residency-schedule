defmodule ResidencySchedule.ScheduleBuilder.DutyHours do
  @moduledoc """
  Validates ACGME 80-hour duty hour rules for a schedule builder state.

  The rule: no resident may average more than 80 hours per week over any
  rolling 4-week window. Hours are computed per slot:
  - Weekday slot (Mon–Fri, 5 days): rotation_daily_hours × 5
  - Weekend slot (Sat–Sun, 2 days): rotation_daily_hours × 2
  """

  @twelve_hour_rotations ~w(
    strong_obstetrics
    oncology
    strong_gynecology
    night_float
    highland_obstetrics
    strong_weekend_days
    strong_weekend_nights
    highland_gynecology
    highland_weekend_nights
    highland_weekend_days
    highland_night_float
  )a

  @nine_hour_rotations ~w(
    ambulatory
    rei
    urogynecology
    elective
    swing
    ultrasound
  )a

  @hours_by_name Map.new(@twelve_hour_rotations, &{Atom.to_string(&1), 12})
                 |> Map.merge(Map.new(@nine_hour_rotations, &{Atom.to_string(&1), 9}))

  @doc """
  Returns the daily hours for a given rotation type, as an atom or the string
  form stored in the database.

  Returns 12 for 12-hour shifts, 9 for 9-hour shifts, and 0 for off-service.

      iex> ResidencySchedule.ScheduleBuilder.DutyHours.hours_for_rotation("night_float")
      12

      iex> ResidencySchedule.ScheduleBuilder.DutyHours.hours_for_rotation("vacation")
      0

      iex> ResidencySchedule.ScheduleBuilder.DutyHours.hours_for_rotation(:strong_obstetrics)
      12

      iex> ResidencySchedule.ScheduleBuilder.DutyHours.hours_for_rotation(:ambulatory)
      9

      iex> ResidencySchedule.ScheduleBuilder.DutyHours.hours_for_rotation(:vacation)
      0
  """
  def hours_for_rotation(rotation_type) when is_binary(rotation_type),
    do: Map.get(@hours_by_name, rotation_type, 0)

  def hours_for_rotation(rotation_type) when rotation_type in @twelve_hour_rotations, do: 12
  def hours_for_rotation(rotation_type) when rotation_type in @nine_hour_rotations, do: 9
  def hours_for_rotation(_), do: 0

  @doc """
  Computes the total hours for a resident in a single slot.

      iex> slot = %{is_weekend: false}
      iex> ResidencySchedule.ScheduleBuilder.DutyHours.slot_hours(:strong_obstetrics, slot)
      60

      iex> slot = %{is_weekend: true}
      iex> ResidencySchedule.ScheduleBuilder.DutyHours.slot_hours(:ambulatory, slot)
      18
  """
  def slot_hours(rotation_type, %{is_weekend: false}), do: hours_for_rotation(rotation_type) * 5
  def slot_hours(rotation_type, %{is_weekend: true}), do: hours_for_rotation(rotation_type) * 2

  @doc """
  Computes the average weekly hours for a resident over a list of slots.

  Returns the total hours divided by the number of weekday slots in the window
  (each weekday slot = 1 week).

      iex> slots = [%{slot_index: 0, is_weekend: false}, %{slot_index: 1, is_weekend: true},
      ...>          %{slot_index: 2, is_weekend: false}, %{slot_index: 3, is_weekend: true},
      ...>          %{slot_index: 4, is_weekend: false}, %{slot_index: 5, is_weekend: true},
      ...>          %{slot_index: 6, is_weekend: false}, %{slot_index: 7, is_weekend: true}]
      iex> assignments = %{{0, 0} => :ambulatory, {0, 2} => :ambulatory, {0, 4} => :ambulatory, {0, 6} => :ambulatory}
      iex> ResidencySchedule.ScheduleBuilder.DutyHours.weekly_avg_hours(0, slots, assignments)
      45.0
  """
  def weekly_avg_hours(resident_index, slots, assignments) do
    total_hours =
      slots
      |> Enum.reduce(0, fn slot, acc ->
        rotation_type = Map.get(assignments, {resident_index, slot.slot_index})
        acc + slot_hours(rotation_type || :float, slot)
      end)

    weekday_count = Enum.count(slots, &(!&1.is_weekend))

    if weekday_count == 0, do: 0.0, else: total_hours / weekday_count
  end

  @doc """
  Returns all duty hour violations for a set of assignments.

  A violation occurs when the average weekly hours over any rolling 4-weekday-slot
  window exceeds 80 for any resident.

  Returns a list of violation maps, each with:
  - `resident_index` — zero-based index into the residents list
  - `window_start_slot` — slot_index of the first weekday slot in the window
  - `weekly_avg` — the computed average weekly hours (float)

      iex> slots = [%{slot_index: 0, is_weekend: false}, %{slot_index: 2, is_weekend: false},
      ...>          %{slot_index: 4, is_weekend: false}, %{slot_index: 6, is_weekend: false}]
      iex> assignments = %{
      ...>   {0, 0} => :strong_obstetrics, {0, 2} => :strong_obstetrics,
      ...>   {0, 4} => :strong_obstetrics, {0, 6} => :strong_obstetrics
      ...> }
      iex> violations = ResidencySchedule.ScheduleBuilder.DutyHours.violations(assignments, slots, [%{residency_year: 1}])
      iex> violations
      []
  """
  def violations(assignments, slots, residents) do
    weekday_slots = Enum.filter(slots, &(!&1.is_weekend))

    residents
    |> Enum.with_index()
    |> Enum.flat_map(fn {_resident, res_idx} ->
      find_resident_violations(res_idx, weekday_slots, slots, assignments)
    end)
  end

  # --- Private ---

  defp find_resident_violations(res_idx, weekday_slots, all_slots, assignments) do
    weekday_slots
    |> Enum.chunk_every(4, 1, :discard)
    |> Enum.flat_map(fn window_weekday ->
      first_slot_idx = hd(window_weekday).slot_index
      # Include the weekend slot immediately following each weekday in the window,
      # as those weekend shifts count toward hours for that week.
      weekday_indices = MapSet.new(Enum.map(window_weekday, & &1.slot_index))
      weekday_adjacent_weekends = MapSet.new(Enum.map(window_weekday, &(&1.slot_index + 1)))

      window_all =
        Enum.filter(all_slots, fn s ->
          cond do
            not s.is_weekend -> s.slot_index in weekday_indices
            s.is_weekend -> s.slot_index in weekday_adjacent_weekends
          end
        end)

      avg = weekly_avg_hours(res_idx, window_all, assignments)

      if avg > 80 do
        [%{resident_index: res_idx, window_start_slot: first_slot_idx, weekly_avg: avg}]
      else
        []
      end
    end)
  end
end
