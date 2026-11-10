defmodule ResidencySchedule.EffectiveSchedule.Policies.GapFill do
  @moduledoc "Version 1 independent dated duties, preserving simultaneous evidence."
  alias ResidencySchedule.EffectiveSchedule.{Evidence, Normalize}
  alias ResidencySchedule.EffectiveSchedule.Policies.SaturdayHighlandGap

  @doc """
  Indexes segments by membership and date.

      iex> segment = %{schedule_resident_id: 2, start_date: ~D[2026-11-03], end_date: ~D[2026-11-03], rotation_type: "elective"}
      iex> ResidencySchedule.EffectiveSchedule.Policies.GapFill.index([segment])[{2, ~D[2026-11-03]}]
      [segment]
  """
  def index(segments) do
    Enum.reduce(segments, %{}, fn segment, acc ->
      Enum.reduce(Date.range(segment.start_date, segment.end_date), acc, fn date, acc ->
        Map.update(acc, {segment.schedule_resident_id, date}, [segment], &[segment | &1])
      end)
    end)
  end

  @doc """
  Builds dated duties from accepted occurrence evidence.

      iex> fact = %{activity: %{id: 1, schedule_resident_id: 2, date: ~D[2026-11-03], raw_task: "Ultrasound"}, source_id: 3, targets: ["ultrasound"], policy: "unique_equivalence_v1", timing: %{precision: :period, period: "AM"}}
      iex> {[entry], []} = ResidencySchedule.EffectiveSchedule.Policies.GapFill.apply([fact], [])
      iex> {entry.duty.kind, entry.duty.code, entry.duty.timing.period}
      {:gap_fill, "ultrasound", "AM"}
  """
  def apply(facts, segments) do
    bases = index(segments)

    facts
    |> Enum.sort_by(&{&1.activity.id, &1.source_id})
    |> Enum.reduce({[], []}, fn fact, {entries, diagnostics} ->
      activity = fact.activity
      day_bases = Map.get(bases, {activity.schedule_resident_id, activity.date}, [])
      {code, reason} = SaturdayHighlandGap.resolve(fact, day_bases)

      diagnostics =
        if reason,
          do: [Evidence.diagnostic(activity, fact.source_id, reason) | diagnostics],
          else: diagnostics

      cond do
        Enum.any?(day_bases, &(&1.is_coverage or not is_nil(&1.covered_by))) ->
          {entries, diagnostics}

        fact.timing.precision == :date_only and Enum.any?(day_bases, &(&1.rotation_type == code)) ->
          {entries, diagnostics}

        true ->
          {[entry(fact, code, day_bases) | entries], diagnostics}
      end
    end)
    |> then(fn {entries, diagnostics} ->
      {entries |> Enum.reverse() |> Enum.uniq_by(&{&1.schedule_resident_id, &1.date, &1.duty}),
       diagnostics}
    end)
  end

  defp entry(fact, code, bases) do
    a = fact.activity

    segment = %{
      rotation_type: code,
      start_date: a.date,
      end_date: a.date,
      slot_index: -1,
      is_coverage: false,
      covered_by: nil,
      original_resident: nil,
      source_assignment_date: a.date,
      source_tasks: [a.raw_task]
    }

    duty =
      segment
      |> Normalize.duty_from_segment()
      |> Map.merge(%{
        kind: if(bases == [], do: :gap_fill, else: :dated_activity),
        timing: fact.timing
      })

    %{
      schedule_resident_id: a.schedule_resident_id,
      date: a.date,
      duty: duty,
      activity_id: a.id,
      source_id: fact.source_id
    }
  end
end
