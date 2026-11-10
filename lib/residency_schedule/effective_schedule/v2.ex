defmodule ResidencySchedule.EffectiveSchedule.V2 do
  @moduledoc "Independent retained-evidence effective schedule computation."
  alias ResidencySchedule.EffectiveSchedule.{Calendar, Evidence, Inputs, Normalize}

  alias ResidencySchedule.EffectiveSchedule.Policies.{
    CoveragePrecedence,
    FridayStrongCorrection,
    GapFill,
    NightBoundary
  }

  alias ResidencySchedule.Ical

  @doc "Computes one schedule with batched source evidence. Database operation; covered by V2EvidenceTest and V2PoliciesTest."
  def compute(schedule_id) do
    inputs = Inputs.load(schedule_id)

    members =
      inputs.members |> Enum.filter(&(&1.schedule_id == schedule_id)) |> Enum.sort_by(& &1.id)

    member_ids = MapSet.new(members, & &1.id)
    {facts, diagnostics} = Evidence.resolve(inputs)

    segments =
      inputs.rotations
      |> NightBoundary.apply(facts, inputs.overrides)
      |> FridayStrongCorrection.apply(facts, inputs.overrides)
      |> CoveragePrecedence.apply(inputs.overrides)

    {entries, context_diagnostics} = GapFill.apply(facts, segments)
    segments = Enum.filter(segments, &MapSet.member?(member_ids, &1.schedule_resident_id))
    entries = Enum.filter(entries, &MapSet.member?(member_ids, &1.schedule_resident_id))

    diagnostics =
      (diagnostics ++ context_diagnostics)
      |> Enum.filter(&MapSet.member?(member_ids, &1.schedule_resident_id))
      |> Enum.uniq()
      |> Enum.sort_by(
        &{&1.schedule_resident_id, Date.to_gregorian_days(&1.date), &1.activity_id,
         &1.activity_source_id, &1.reason}
      )

    %{
      records: records(members, segments, entries),
      segments: segments,
      entries: entries,
      diagnostics: diagnostics,
      members: members
    }
  end

  @doc """
  Returns calendar events for one membership from a loaded computation.

      iex> segment = %{schedule_resident_id: 2, rotation_type: "vacation", start_date: ~D[2026-11-03], end_date: ~D[2026-11-03], covered_by: nil, source_tasks: []}
      iex> [event] = ResidencySchedule.EffectiveSchedule.V2.events(%{segments: [segment], entries: []}, 2)
      iex> {event.dtstart, event.dtend, event.summary}
      {"20261103", "20261104", "Vacation"}
  """
  def events(result, member_id) do
    baseline =
      result.segments
      |> Enum.filter(&(&1.schedule_resident_id == member_id))
      |> Ical.events_from_segments("")

    dated =
      result.entries
      |> Enum.filter(&(&1.schedule_resident_id == member_id))
      |> Enum.map(&Calendar.event/1)

    Enum.sort_by(baseline ++ dated, &{&1.dtstart, &1.uid})
  end

  defp records(_members, [], []), do: []

  defp records(members, segments, entries) do
    index =
      segments
      |> GapFill.index()
      |> Map.new(fn {key, segments} ->
        {key, Enum.map(segments, &Normalize.duty_from_segment/1)}
      end)

    index =
      Enum.reduce(entries, index, fn e, acc ->
        Map.update(acc, {e.schedule_resident_id, e.date}, [e.duty], &[e.duty | &1])
      end)

    dates = Enum.map(Map.keys(index), &elem(&1, 1))
    range = Date.range(Enum.min(dates, Date), Enum.max(dates, Date))

    for member <- members, date <- range do
      duties = index |> Map.get({member.id, date}, []) |> Normalize.sort_duties()

      %{
        person_id: member.resident_id,
        schedule_resident_id: member.id,
        schedule_id: member.schedule_id,
        date: date,
        duties: duties,
        off: Normalize.off_state(duties)
      }
    end
  end
end
