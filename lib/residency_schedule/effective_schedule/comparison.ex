defmodule ResidencySchedule.EffectiveSchedule.Comparison do
  @moduledoc """
  Compares the `:legacy` and `:v2` effective-schedule reads of one schedule.

  Results are returned in memory only (plan D5): nothing is persisted, logged
  or written to a file. Telemetry receives only the aggregate mismatch count.
  """

  alias ResidencySchedule.EffectiveSchedule
  alias ResidencySchedule.EffectiveSchedule.V2
  alias ResidencySchedule.Observability.Tracing
  alias ResidencySchedule.Residents

  @doc """
  Runs the comparison for a schedule and returns aggregate counts with the
  differing records as detail. Returns `{:error, :not_found}` for an unknown
  schedule.

  Exempt from doctest — hits the database. See `ComparisonTest`.
  """
  def run(schedule_id) do
    Tracing.phase(:schedule_compare, fn -> compare_schedule(schedule_id) end)
  end

  @doc """
  Diffs two daily record lists keyed by schedule resident and date.

  Returns the number of identical records and the differing days, sorted by
  schedule resident then chronological date, each with both versions (nil
  when a side has no record).

      iex> alias ResidencySchedule.EffectiveSchedule.Comparison
      iex> legacy = %{schedule_resident_id: 1, date: ~D[2026-07-06], duties: [], off: :blank}
      iex> v2 = %{legacy | off: :vacation}
      iex> Comparison.diff_days([legacy], [v2])
      {0, [%{schedule_resident_id: 1, date: ~D[2026-07-06], legacy: legacy, v2: v2}]}

      iex> alias ResidencySchedule.EffectiveSchedule.Comparison
      iex> record = %{schedule_resident_id: 1, date: ~D[2026-07-06], duties: [], off: :blank}
      iex> Comparison.diff_days([record], [record])
      {1, []}
  """
  def diff_days(legacy, v2) do
    legacy_by_key = index_days(legacy)
    v2_by_key = index_days(v2)

    legacy_by_key
    |> Map.keys()
    |> Enum.concat(Map.keys(v2_by_key))
    |> Enum.uniq()
    |> Enum.sort_by(fn {resident_id, date} -> {resident_id, Date.to_gregorian_days(date)} end)
    |> Enum.reduce({0, []}, &collect_day(&1, legacy_by_key, v2_by_key, &2))
    |> reverse_differing()
  end

  @doc """
  Diffs calendar identity sets keyed by person. Returns one entry per event
  present on only one side, ordered by person then legacy-only before v2-only.

      iex> alias ResidencySchedule.EffectiveSchedule.Comparison
      iex> event = %{uid: "seg-vacation-2026-07-06@residency-schedule", dtstart: "20260706", dtend: "20260707", summary: "Vacation"}
      iex> Comparison.diff_events(%{5 => [event]}, %{5 => []})
      [%{person_id: 5, legacy: event, v2: nil}]

      iex> alias ResidencySchedule.EffectiveSchedule.Comparison
      iex> event = %{uid: "seg-vacation-2026-07-06@residency-schedule", dtstart: "20260706", dtend: "20260707", summary: "Vacation"}
      iex> Comparison.diff_events(%{5 => [event]}, %{5 => [event]})
      []
  """
  def diff_events(legacy, v2) do
    legacy
    |> Map.keys()
    |> Enum.concat(Map.keys(v2))
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.flat_map(&person_event_differences(&1, legacy, v2))
  end

  defp compare_schedule(schedule_id) do
    with {:ok, legacy} <- EffectiveSchedule.for_schedule(schedule_id, :legacy) do
      {:ok, build_summary(schedule_id, legacy, V2.compute(schedule_id))}
    end
  end

  defp build_summary(schedule_id, legacy, result) do
    v2 = result.records
    {identical_days, differing_days} = diff_days(legacy, v2)
    people = result.members |> Enum.map(& &1.resident_id) |> Enum.uniq()

    differing_events =
      diff_events(person_events(people, :legacy), v2_person_events(people, schedule_id, result))

    evidence = result.diagnostics
    Tracing.count(:mismatches, length(differing_days) + length(differing_events))
    Tracing.count(:unresolved_evidence, length(evidence))

    %{
      schedule_id: schedule_id,
      identical_days: identical_days,
      differing_days: length(differing_days),
      differing_calendar_events: length(differing_events),
      differing_consumer_outputs: 0,
      unresolved_evidence: length(evidence),
      detail: %{days: differing_days, calendar_events: differing_events, evidence: evidence}
    }
  end

  defp v2_person_events(people, schedule_id, result) do
    appearances =
      people
      |> Map.new(&{&1, Residents.list_appearances_for_person(&1)})

    computations =
      appearances
      |> Map.values()
      |> List.flatten()
      |> Enum.map(& &1.schedule_id)
      |> Enum.uniq()
      |> Enum.reduce(%{schedule_id => result}, fn id, cache ->
        Map.put_new_lazy(cache, id, fn -> V2.compute(id) end)
      end)

    Map.new(appearances, fn {person_id, memberships} ->
      events =
        memberships
        |> Enum.flat_map(&V2.events(Map.fetch!(computations, &1.schedule_id), &1.id))
        |> Enum.sort_by(&{&1.dtstart, &1.uid})

      {person_id, events}
    end)
  end

  defp person_events(people, version) do
    Map.new(people, &{&1, calendar_events(&1, version)})
  end

  defp calendar_events(person_id, version) do
    {:ok, events} = EffectiveSchedule.calendar_events(person_id, version)
    events
  end

  defp index_days(records), do: Map.new(records, &{{&1.schedule_resident_id, &1.date}, &1})

  defp collect_day({resident_id, date} = key, legacy_by_key, v2_by_key, {identical, differing}) do
    legacy = Map.get(legacy_by_key, key)
    v2 = Map.get(v2_by_key, key)

    if legacy == v2 do
      {identical + 1, differing}
    else
      {identical,
       [%{schedule_resident_id: resident_id, date: date, legacy: legacy, v2: v2} | differing]}
    end
  end

  defp reverse_differing({identical, differing}), do: {identical, Enum.reverse(differing)}

  defp person_event_differences(person_id, legacy, v2) do
    legacy_events = Map.get(legacy, person_id, [])
    v2_events = Map.get(v2, person_id, [])

    only_in(legacy_events, v2_events, &%{person_id: person_id, legacy: &1, v2: nil}) ++
      only_in(v2_events, legacy_events, &%{person_id: person_id, legacy: nil, v2: &1})
  end

  defp only_in(events, others, build) do
    others = MapSet.new(others)

    events
    |> Enum.reject(&MapSet.member?(others, &1))
    |> Enum.map(build)
  end
end
