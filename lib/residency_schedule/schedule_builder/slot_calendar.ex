defmodule ResidencySchedule.ScheduleBuilder.SlotCalendar do
  @moduledoc """
  Generates the slot calendar for a given academic year.

  Each academic year covers 52 calendar weeks starting from the Monday of the
  week containing July 1. Four of those weeks are FLOAT (curriculum) weeks,
  represented as single 7-day Mon–Sun slots. The remaining 48 weeks produce a
  weekday (Mon–Fri) slot and a weekend (Sat–Sun) slot each, for a total of 100
  slots per year.

  FLOAT weeks:
  - Holiday FLOAT: 2 weeks starting 14 days before the first Monday of January.
  - End-of-year FLOAT: 2 weeks starting 14 days before the next year's term start.
  """

  @doc """
  Builds the full slot list for an academic year.

  Returns a list of 100 maps ordered by slot_index. FLOAT weeks appear as
  single 7-day slots (`end_date - start_date == 6`, `is_weekend: false`).
  All other weeks produce a Mon–Fri weekday slot and a Sat–Sun weekend slot.

      iex> slots = ResidencySchedule.ScheduleBuilder.SlotCalendar.build_slots(2026)
      iex> length(slots)
      100
      iex> hd(slots).is_weekend
      false
      iex> Date.day_of_week(hd(slots).start_date)
      1
  """
  def build_slots(academic_year) do
    start_monday = first_monday_of_academic_year(academic_year)
    float_mondays = compute_float_mondays(academic_year)
    generate_slots(start_monday, float_mondays)
  end

  @doc """
  Returns a MapSet of slot indices that are FLOAT (curriculum) weeks.

  FLOAT slots span exactly 7 days (Mon–Sun), unlike regular weekday slots
  (Mon–Fri, 5 days). The `academic_year` parameter is accepted for API
  compatibility but detection is done by span.

      iex> slots = ResidencySchedule.ScheduleBuilder.SlotCalendar.build_slots(2025)
      iex> float_slots = ResidencySchedule.ScheduleBuilder.SlotCalendar.float_slot_indices(2025, slots)
      iex> MapSet.size(float_slots)
      4
      iex> Enum.find(slots, & &1.slot_index in float_slots and &1.start_date == ~D[2025-12-22]) != nil
      true
  """
  def float_slot_indices(_academic_year, slots) do
    slots
    |> Enum.filter(fn slot -> Date.diff(slot.end_date, slot.start_date) == 6 end)
    |> MapSet.new(& &1.slot_index)
  end

  @doc """
  Returns the slots in a rolling window of `window_size` non-weekend slots
  left-aligned at `slot_index`. Weekend slots within the range are included
  in the result. FLOAT slots count toward the window like weekday slots.

  Clamps to available slots at both boundaries.

      iex> slots = ResidencySchedule.ScheduleBuilder.SlotCalendar.build_slots(2026)
      iex> window = ResidencySchedule.ScheduleBuilder.SlotCalendar.slots_for_window(slots, 0, 4)
      iex> weekday_count = Enum.count(window, & !&1.is_weekend)
      iex> weekday_count
      4
  """
  def slots_for_window(slots, start_slot_index, window_size \\ 4) do
    non_weekend_indices =
      slots
      |> Enum.filter(&(!&1.is_weekend))
      |> Enum.map(& &1.slot_index)

    window_non_weekend_indices =
      non_weekend_indices
      |> Enum.drop_while(&(&1 < start_slot_index))
      |> Enum.take(window_size)

    case window_non_weekend_indices do
      [] ->
        []

      indices ->
        first_idx = List.first(indices)
        last_idx = List.last(indices)

        slots
        |> Enum.filter(fn s -> s.slot_index >= first_idx and s.slot_index <= last_idx end)
    end
  end

  # --- Private ---

  defp compute_float_mondays(academic_year) do
    holiday_start = holiday_float_start(academic_year)
    end_of_year_start = end_of_year_float_start(academic_year)

    MapSet.new([
      holiday_start,
      Date.add(holiday_start, 7),
      end_of_year_start,
      Date.add(end_of_year_start, 7)
    ])
  end

  defp generate_slots(start_monday, float_mondays) do
    generate_slots_loop(start_monday, float_mondays, [], 0)
  end

  defp generate_slots_loop(_monday, _float_mondays, acc, idx) when idx >= 100 do
    Enum.reverse(acc)
  end

  defp generate_slots_loop(monday, float_mondays, acc, idx) do
    if MapSet.member?(float_mondays, monday) do
      slot = %{
        slot_index: idx,
        start_date: monday,
        end_date: Date.add(monday, 6),
        is_weekend: false
      }

      generate_slots_loop(Date.add(monday, 7), float_mondays, [slot | acc], idx + 1)
    else
      wd = %{
        slot_index: idx,
        start_date: monday,
        end_date: Date.add(monday, 4),
        is_weekend: false
      }

      we = %{
        slot_index: idx + 1,
        start_date: Date.add(monday, 5),
        end_date: Date.add(monday, 6),
        is_weekend: true
      }

      generate_slots_loop(Date.add(monday, 7), float_mondays, [we, wd | acc], idx + 2)
    end
  end

  # Holiday FLOAT starts 14 days before the first Monday of January of the following year.
  defp holiday_float_start(academic_year) do
    Date.add(first_monday_of_january(academic_year + 1), -14)
  end

  # End-of-year FLOAT starts 14 days before the start of the next academic year.
  defp end_of_year_float_start(academic_year) do
    Date.add(first_monday_of_academic_year(academic_year + 1), -14)
  end

  # Returns the first Monday of January for the given year (on or after Jan 1).
  defp first_monday_of_january(year) do
    jan_first = Date.new!(year, 1, 1)
    dow = Date.day_of_week(jan_first)
    Date.add(jan_first, rem(8 - dow, 7))
  end

  # Returns the Monday of the week that contains July 1.
  # If July 1 is Monday, returns July 1.
  # Otherwise returns the preceding Monday (may be in late June).
  defp first_monday_of_academic_year(year) do
    july_first = Date.new!(year, 7, 1)
    dow = Date.day_of_week(july_first)
    Date.add(july_first, 1 - dow)
  end
end
