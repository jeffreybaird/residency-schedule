defmodule ResidencySchedule.EffectiveSchedule do
  @moduledoc """
  Computes schedule meaning as daily duty records and calendar identity sets.

  The fixed interface of plan D2. `version` selects the computation: `:legacy`
  adapts the existing projection paths; `:v2` computes from retained source
  evidence through named policies without changing production consumers.
  """

  alias ResidencySchedule.EffectiveSchedule.LegacyAdapter
  alias ResidencySchedule.EffectiveSchedule.V2
  alias ResidencySchedule.Ical
  alias ResidencySchedule.Residents
  alias ResidencySchedule.Rotations
  alias ResidencySchedule.Schedules

  @versions [:legacy, :v2]

  @doc """
  Daily records for every membership of a schedule, sorted by schedule
  resident then date. Returns `{:error, :not_found}` for an unknown schedule
  and `{:error, :unknown_version}` for a version other than `:legacy` or `:v2`.

  Exempt from doctest — hits the database. See `EffectiveScheduleTest`.
  """
  def for_schedule(schedule_id, version) do
    with :ok <- validate_version(version),
         {:ok, schedule} <- fetch_schedule(schedule_id) do
      {:ok, schedule_records(schedule.id, version)}
    end
  end

  @doc """
  Daily records for every schedule appearance of a person, sorted by schedule
  then date. An unknown person has no records.

  Exempt from doctest — hits the database. See `EffectiveScheduleTest`.
  """
  def for_person(person_id, version) do
    with :ok <- validate_version(version) do
      {:ok, person_records(person_id, version)}
    end
  end

  @doc """
  Daily records for one date of a schedule, one per membership.

  Exempt from doctest — hits the database. See `EffectiveScheduleTest`.
  """
  def for_date(schedule_id, date, version) do
    with {:ok, records} <- for_schedule(schedule_id, version) do
      {:ok, Enum.filter(records, &(Date.compare(&1.date, date) == :eq))}
    end
  end

  @doc """
  The calendar identity set (plan D1) for every appearance of a person,
  sorted by start then uid. An unknown person has no events.

  Exempt from doctest — hits the database. See `EffectiveScheduleTest`.
  """
  def calendar_events(person_id, version) do
    with :ok <- validate_version(version) do
      {:ok, person_events(person_id, version)}
    end
  end

  @doc """
  Returns bounded unresolved occurrence evidence in deterministic order.
  Details remain in memory; legacy reads have no evidence diagnostics.
  Exempt from doctest — database operation; covered by V2EvidenceTest.
  """
  def evidence_diagnostics(schedule_id, version) do
    with :ok <- validate_version(version), {:ok, schedule} <- fetch_schedule(schedule_id) do
      {:ok, if(version == :v2, do: V2.compute(schedule.id).diagnostics, else: [])}
    end
  end

  defp validate_version(version) when version in @versions, do: :ok
  defp validate_version(_version), do: {:error, :unknown_version}

  defp fetch_schedule(schedule_id) do
    case Schedules.get_schedule(schedule_id) do
      nil -> {:error, :not_found}
      schedule -> {:ok, schedule}
    end
  end

  defp schedule_records(schedule_id, :legacy),
    do: LegacyAdapter.daily_records_for_schedule(schedule_id)

  defp schedule_records(schedule_id, :v2),
    do: V2.compute(schedule_id).records

  defp person_records(person_id, version) do
    person_id
    |> Residents.list_appearances_for_person()
    |> Enum.sort_by(& &1.schedule_id)
    |> Enum.flat_map(&appearance_records(&1, version))
  end

  defp appearance_records(appearance, version) do
    appearance.schedule_id
    |> schedule_records(version)
    |> Enum.filter(&(&1.schedule_resident_id == appearance.id))
  end

  defp person_events(person_id, :legacy), do: legacy_person_events(person_id)

  defp person_events(person_id, :v2) do
    person_id
    |> Residents.list_appearances_for_person()
    |> Enum.group_by(& &1.schedule_id)
    |> Enum.flat_map(fn {schedule_id, appearances} ->
      result = V2.compute(schedule_id)
      Enum.flat_map(appearances, &V2.events(result, &1.id))
    end)
    |> Enum.sort_by(&{&1.dtstart, &1.uid})
  end

  defp legacy_person_events(person_id) do
    person_id
    |> Rotations.effective_segments_for_person()
    |> Ical.events_from_segments(person_name(person_id))
    |> Enum.sort_by(&{&1.dtstart, &1.uid})
  end

  defp person_name(person_id) do
    case Residents.list_appearances_for_person(person_id) do
      [] -> ""
      [appearance | _] -> appearance.name
    end
  end
end
