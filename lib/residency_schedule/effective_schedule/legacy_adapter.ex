defmodule ResidencySchedule.EffectiveSchedule.LegacyAdapter do
  @moduledoc """
  Computes daily duty records from the existing projection and override paths.

  This is the `:legacy` version of the effective-schedule service (plan D2):
  an adapter over `Rotations.effective_segments_for_schedule/1`, so the
  comparison harness starts at zero differences by construction.
  """

  alias ResidencySchedule.EffectiveSchedule.Normalize
  alias ResidencySchedule.Residents
  alias ResidencySchedule.Rotations

  @doc """
  Daily records for every membership of a schedule, sorted by schedule
  resident then date. A schedule without effective segments has no records.

  Exempt from doctest — hits the database. See `EffectiveScheduleTest`.
  """
  def daily_records_for_schedule(schedule_id) do
    segments_by_resident = Rotations.effective_segments_for_schedule(schedule_id)

    case schedule_range(segments_by_resident) do
      nil ->
        []

      range ->
        schedule_id
        |> Residents.list_residents_for_schedule()
        |> Enum.sort_by(& &1.id)
        |> Enum.flat_map(&resident_records(&1, segments_by_resident, range))
    end
  end

  defp resident_records(schedule_resident, segments_by_resident, range) do
    segments_by_resident
    |> Map.get(schedule_resident.id, [])
    |> Normalize.daily_records(membership(schedule_resident), range)
  end

  defp membership(schedule_resident) do
    %{
      person_id: schedule_resident.resident_id,
      schedule_resident_id: schedule_resident.id,
      schedule_id: schedule_resident.schedule_id
    }
  end

  defp schedule_range(segments_by_resident) do
    segments_by_resident
    |> Map.values()
    |> List.flatten()
    |> range_of_segments()
  end

  defp range_of_segments([]), do: nil

  defp range_of_segments(segments) do
    Date.range(
      segments |> Enum.map(& &1.start_date) |> Enum.min(Date),
      segments |> Enum.map(& &1.end_date) |> Enum.max(Date)
    )
  end
end
