defmodule ResidencySchedule.Ical do
  alias ResidencySchedule.Rotations

  @night_shift_types ~w[night_float strong_weekend_nights highland_night_float highland_weekend_nights]
  @all_day_types ~w[vacation post_call float]

  @doc """
  Builds an iCal (VCALENDAR) string for a resident's full schedule.

  Night shift types (night float, weekend nights) generate 6pm→6am events,
  with the start time shifted to the evening before each listed date. Day shifts
  generate 6am→6pm events. Vacation, post-call, and float are rendered as a
  single all-day event spanning the full block.

  When a day-shift or all-day block is immediately followed by a night-shift block,
  the last day of the preceding block is omitted — that day is a transition day
  with no day-shift work.

      iex> resident = %{name: "Test", rotations: []}
      iex> result = ResidencySchedule.Ical.build(resident)
      iex> String.contains?(result, "BEGIN:VCALENDAR")
      true
  """
  def build(resident) do
    events =
      resident.rotations
      |> Enum.sort_by(& &1.start_date, Date)
      |> build_all_events(resident)

    """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//ResidencySchedule//EN
    CALSCALE:GREGORIAN
    X-WR-CALNAME:#{resident.name} – Schedule
    #{Enum.join(events, "")}END:VCALENDAR
    """
  end

  @doc """
  Returns true if the given rotation type is a night shift.

      iex> ResidencySchedule.Ical.night_shift?("night_float")
      true

      iex> ResidencySchedule.Ical.night_shift?("ambulatory")
      false
  """
  def night_shift?(type), do: type in @night_shift_types

  @doc """
  Returns true if the given rotation type is rendered as an all-day calendar event.

      iex> ResidencySchedule.Ical.all_day?("vacation")
      true

      iex> ResidencySchedule.Ical.all_day?("post_call")
      true

      iex> ResidencySchedule.Ical.all_day?("float")
      true

      iex> ResidencySchedule.Ical.all_day?("ambulatory")
      false
  """
  def all_day?(type), do: type in @all_day_types

  @doc """
  Returns true if the last day of `rotation` should be trimmed because
  `next_rotation` is a night shift starting the immediately following calendar day.

      iex> r = %{end_date: ~D[2026-03-06], rotation_type: "ambulatory"}
      iex> next = %{start_date: ~D[2026-03-07], rotation_type: "night_float"}
      iex> ResidencySchedule.Ical.trim_last_day?(r, next)
      true

      iex> r = %{end_date: ~D[2026-03-06], rotation_type: "ambulatory"}
      iex> next = %{start_date: ~D[2026-03-07], rotation_type: "ambulatory"}
      iex> ResidencySchedule.Ical.trim_last_day?(r, next)
      false

      iex> r = %{end_date: ~D[2026-03-06], rotation_type: "night_float"}
      iex> next = %{start_date: ~D[2026-03-07], rotation_type: "night_float"}
      iex> ResidencySchedule.Ical.trim_last_day?(r, next)
      false

      iex> r = %{end_date: ~D[2026-03-06], rotation_type: "ambulatory"}
      iex> ResidencySchedule.Ical.trim_last_day?(r, nil)
      false
  """
  def trim_last_day?(_rotation, nil), do: false

  def trim_last_day?(rotation, next_rotation) do
    !night_shift?(rotation.rotation_type) &&
      night_shift?(next_rotation.rotation_type) &&
      Date.diff(next_rotation.start_date, rotation.end_date) == 1
  end

  @doc """
  Returns the {dtstart, dtend} strings for a single timed calendar-day event.

  Night shifts start at 6pm the previous evening and end at 6am of the listed date.
  All other timed shifts run 6am–6pm on the listed date.

      iex> {start, _} = ResidencySchedule.Ical.event_times("night_float", ~D[2026-03-09])
      iex> start
      "20260308T180000"

      iex> {_, finish} = ResidencySchedule.Ical.event_times("night_float", ~D[2026-03-09])
      iex> finish
      "20260309T060000"

      iex> {start, finish} = ResidencySchedule.Ical.event_times("ambulatory", ~D[2026-03-09])
      iex> {start, finish}
      {"20260309T060000", "20260309T180000"}
  """
  def event_times(rotation_type, date) do
    if night_shift?(rotation_type) do
      {format_datetime(Date.add(date, -1), 18), format_datetime(date, 6)}
    else
      {format_datetime(date, 6), format_datetime(date, 18)}
    end
  end

  # ── Private ──────────────────────────────────────────────────────────────────

  defp build_all_events(sorted_rotations, resident) do
    sorted_rotations
    |> Enum.with_index()
    |> Enum.flat_map(fn {rotation, idx} ->
      next = Enum.at(sorted_rotations, idx + 1)
      trim = trim_last_day?(rotation, next)

      if all_day?(rotation.rotation_type) do
        [build_all_day_event(resident, rotation, trim)]
      else
        build_timed_events(resident, rotation, trim)
      end
    end)
  end

  defp build_all_day_event(resident, rotation, trim_last) do
    uid = "rotation-#{rotation.id}@residency-schedule"
    label = Rotations.rotation_type_label(rotation.rotation_type)
    dtstart = format_date(rotation.start_date)
    effective_end = if trim_last, do: rotation.end_date, else: Date.add(rotation.end_date, 1)
    dtend = format_date(effective_end)

    """
    BEGIN:VEVENT
    UID:#{uid}
    SUMMARY:#{label}
    DTSTART;VALUE=DATE:#{dtstart}
    DTEND;VALUE=DATE:#{dtend}
    DESCRIPTION:#{resident.name} – #{label}
    END:VEVENT
    """
  end

  defp build_timed_events(resident, rotation, trim_last) do
    rotation.start_date
    |> Date.range(rotation.end_date)
    |> Enum.to_list()
    |> then(fn dates -> if trim_last, do: Enum.drop(dates, -1), else: dates end)
    |> Enum.map(&build_timed_event(resident, rotation, &1))
  end

  defp build_timed_event(resident, rotation, date) do
    uid = "rotation-#{rotation.id}-#{date}@residency-schedule"
    label = Rotations.rotation_type_label(rotation.rotation_type)
    {dtstart, dtend} = event_times(rotation.rotation_type, date)

    """
    BEGIN:VEVENT
    UID:#{uid}
    SUMMARY:#{label}
    DTSTART:#{dtstart}
    DTEND:#{dtend}
    DESCRIPTION:#{resident.name} – #{label}
    END:VEVENT
    """
  end

  defp format_date(date) do
    "#{pad(date.year, 4)}#{pad(date.month, 2)}#{pad(date.day, 2)}"
  end

  defp format_datetime(date, hour) do
    "#{format_date(date)}T#{pad(hour, 2)}0000"
  end

  defp pad(n, width), do: String.pad_leading(to_string(n), width, "0")
end
