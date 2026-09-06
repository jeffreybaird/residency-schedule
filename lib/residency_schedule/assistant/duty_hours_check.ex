defmodule ResidencySchedule.Assistant.DutyHoursCheck do
  @moduledoc """
  Date-based ACGME 80-hour check for a resident's effective schedule, with an
  optional hypothetical coverage added on top.

  Hours are estimates: each day of a rotation contributes that rotation's
  nominal daily hours (see `DutyHours.hours_for_rotation/1`); there are no
  shift times in the data. A violation is any 28-day window whose average
  weekly hours exceed 80. One-in-seven days off and the 24+4 rule are not
  checked.
  """

  alias ResidencySchedule.Rotations
  alias ResidencySchedule.ScheduleBuilder.DutyHours

  @window_days 28
  @weekly_limit 80

  @doc """
  Checks whether a schedule resident covering `rotation_type` on the inclusive
  date range would exceed the limit, compared against their current schedule.

  Exempt from doctest — hits the database. See `DutyHoursCheckTest`.
  """
  def check(schedule_resident_id, rotation_type, start_date, end_date) do
    baseline =
      schedule_resident_id
      |> Rotations.effective_segments_for_resident()
      |> daily_hours()

    hypothetical = with_cover(baseline, rotation_type, start_date, end_date)
    compare(baseline, hypothetical)
  end

  @doc """
  Compares baseline and hypothetical daily-hour maps and reports the result.

      iex> baseline = %{~D[2026-07-06] => 12}
      iex> hypothetical = Map.put(baseline, ~D[2026-07-07], 12)
      iex> result = ResidencySchedule.Assistant.DutyHoursCheck.compare(baseline, hypothetical)
      iex> {result.violates, result.max_weekly_avg, result.estimated}
      {false, 6.0, true}
  """
  def compare(baseline, hypothetical) do
    baseline_violations = violations(baseline)
    all_violations = violations(hypothetical)
    new_violations = all_violations -- baseline_violations

    %{
      violates: new_violations != [],
      already_violating: baseline_violations != [],
      max_weekly_avg: max_weekly_avg(hypothetical),
      baseline_max_weekly_avg: max_weekly_avg(baseline),
      new_violations: new_violations,
      existing_violations: baseline_violations,
      weekly_limit: @weekly_limit,
      window_days: @window_days,
      estimated: true
    }
  end

  @doc """
  Builds a `%{date => hours}` map from effective segments. Segments someone
  else is covering contribute nothing (the resident is off those days).

      iex> segments = [
      ...>   %{rotation_type: "strong_obstetrics", start_date: ~D[2026-07-06], end_date: ~D[2026-07-07], covered_by: nil},
      ...>   %{rotation_type: "ambulatory", start_date: ~D[2026-07-08], end_date: ~D[2026-07-08], covered_by: %{id: 9}}
      ...> ]
      iex> ResidencySchedule.Assistant.DutyHoursCheck.daily_hours(segments)
      %{~D[2026-07-06] => 12, ~D[2026-07-07] => 12}
  """
  def daily_hours(segments) do
    segments
    |> Enum.reject(&(&1.covered_by != nil))
    |> Enum.flat_map(&segment_days/1)
    |> Map.new()
  end

  @doc """
  Replaces the resident's hours on each day of the range with the covered
  rotation's hours, since a covering resident works that shift instead of
  their own.

      iex> daily = %{~D[2026-07-13] => 9}
      iex> ResidencySchedule.Assistant.DutyHoursCheck.with_cover(daily, "strong_obstetrics", ~D[2026-07-13], ~D[2026-07-14])
      %{~D[2026-07-13] => 12, ~D[2026-07-14] => 12}
  """
  def with_cover(daily, rotation_type, start_date, end_date) do
    hours = DutyHours.hours_for_rotation(rotation_type)

    start_date
    |> Date.range(end_date)
    |> Enum.reduce(daily, &Map.put(&2, &1, hours))
  end

  @doc """
  Lists the stretches of days during which some 28-day window (starting on a
  worked day) averages more than 80 hours a week. Overlapping windows are
  merged into one stretch carrying the highest average.

      iex> daily = Map.new(Date.range(~D[2026-07-06], ~D[2026-08-02]), &{&1, 12})
      iex> [v] = ResidencySchedule.Assistant.DutyHoursCheck.violations(daily)
      iex> {v.window_start, v.window_end, v.weekly_avg}
      {~D[2026-07-06], ~D[2026-08-02], 84.0}
  """
  def violations(daily) do
    daily
    |> window_averages()
    |> Enum.filter(&(&1.weekly_avg > @weekly_limit))
    |> coalesce_windows()
  end

  @doc """
  Highest average weekly hours over any 28-day window, or 0.0 when empty.

      iex> daily = Map.new(Date.range(~D[2026-07-06], ~D[2026-07-12]), &{&1, 12})
      iex> ResidencySchedule.Assistant.DutyHoursCheck.max_weekly_avg(daily)
      21.0
  """
  def max_weekly_avg(daily) do
    daily
    |> window_averages()
    |> Enum.map(& &1.weekly_avg)
    |> Enum.max(fn -> 0.0 end)
  end

  defp coalesce_windows(windows) do
    windows
    |> Enum.reduce([], fn window, acc -> merge_window(acc, window) end)
    |> Enum.reverse()
  end

  defp merge_window([], window), do: [window]

  defp merge_window([last | rest] = acc, window) do
    if Date.compare(window.window_start, Date.add(last.window_end, 1)) == :gt do
      [window | acc]
    else
      merged = %{
        window_start: last.window_start,
        window_end: Enum.max([last.window_end, window.window_end], Date),
        weekly_avg: max(last.weekly_avg, window.weekly_avg)
      }

      [merged | rest]
    end
  end

  defp window_averages(daily) when map_size(daily) == 0, do: []

  defp window_averages(daily) do
    dates = daily |> Map.keys() |> Enum.sort(Date)
    last_worked = List.last(dates)
    Enum.map(dates, &window_average(daily, &1, last_worked))
  end

  # The reported window ends on the last worked day inside it, so a stretch
  # never claims days after the resident's schedule ends.
  defp window_average(daily, window_start, last_worked) do
    window_end = Enum.min([Date.add(window_start, @window_days - 1), last_worked], Date)

    total =
      window_start
      |> Date.range(window_end)
      |> Enum.reduce(0, &(&2 + Map.get(daily, &1, 0)))

    %{
      window_start: window_start,
      window_end: window_end,
      weekly_avg: total / (@window_days / 7)
    }
  end

  defp segment_days(segment) do
    hours = DutyHours.hours_for_rotation(segment.rotation_type)

    segment.start_date
    |> Date.range(segment.end_date)
    |> Enum.map(&{&1, hours})
  end
end
