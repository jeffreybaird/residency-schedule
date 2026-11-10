defmodule ResidencySchedule.EffectiveSchedule.Policies.FridayStrongCorrection do
  @moduledoc "Version 1 Friday correction, requiring retained contact policy evidence."

  @doc """
  Recognizes retained Friday trigger policy, independently of display labels.

      iex> ResidencySchedule.EffectiveSchedule.Policies.FridayStrongCorrection.trigger?(%{policy: "friday_strong_correction_v1", targets: ["night_float", "strong_weekend_nights"]})
      true
  """
  def trigger?(fact),
    do:
      fact.policy == "friday_strong_correction_v1" and
        Enum.sort(fact.targets) == ["night_float", "strong_weekend_nights"]

  @doc """
  Projects Friday contact duty from retained policy evidence.

      iex> rotation = %{id: 1, schedule_resident_id: 2, schedule_resident: %{schedule_id: 3}, rotation_type: "ambulatory", start_date: ~D[2026-11-13], end_date: ~D[2026-11-13], source_assignment_date: nil}
      iex> fact = %{activity: %{schedule_resident_id: 2, date: ~D[2026-11-13]}, policy: "friday_strong_correction_v1", targets: ["night_float", "strong_weekend_nights"]}
      iex> [night] = ResidencySchedule.EffectiveSchedule.Policies.FridayStrongCorrection.apply([rotation], [fact], [])
      iex> {night.rotation_type, night.source_assignment_date}
      {"strong_weekend_nights", ~D[2026-11-13]}
  """
  def apply(rotations, facts, overrides) do
    facts_by_day = Enum.group_by(facts, &{&1.activity.schedule_resident_id, &1.activity.date})
    owners = Map.new(rotations, &{&1.id, &1.schedule_resident_id})

    protected =
      overrides
      |> Enum.flat_map(fn o ->
        for day <- Date.range(o.override_start_date, o.override_end_date),
            member <- [Map.get(owners, o.rotation_id), o.covering_schedule_resident_id],
            not is_nil(member),
            do: {member, day}
      end)
      |> MapSet.new()

    triggers =
      rotations
      |> Enum.filter(&(&1.rotation_type == "ambulatory"))
      |> Enum.flat_map(fn r ->
        for day <- Date.range(r.start_date, r.end_date),
            contact?(r, day, facts_by_day, protected),
            do: {r.schedule_resident.schedule_id, day}
      end)
      |> MapSet.new()

    Enum.flat_map(rotations, fn r ->
      r.start_date
      |> Date.range(r.end_date)
      |> Enum.chunk_by(&type(r, &1, facts_by_day, protected, triggers))
      |> Enum.map(fn days ->
        day = hd(days)
        type = type(r, day, facts_by_day, protected, triggers)

        %{
          r
          | start_date: day,
            end_date: List.last(days),
            rotation_type: type,
            source_assignment_date:
              if(r.rotation_type == "ambulatory" and type == "strong_weekend_nights",
                do: day,
                else: r.source_assignment_date
              )
        }
      end)
    end)
  end

  defp contact?(r, day, facts, protected),
    do:
      Date.day_of_week(day) == 5 and not MapSet.member?(protected, {r.schedule_resident_id, day}) and
        Enum.any?(Map.get(facts, {r.schedule_resident_id, day}, []), &trigger?/1)

  defp type(r, day, facts, protected, triggers) do
    key = {r.schedule_resident_id, day}

    cond do
      MapSet.member?(protected, key) ->
        r.rotation_type

      r.rotation_type == "ambulatory" and contact?(r, day, facts, protected) ->
        "strong_weekend_nights"

      r.rotation_type == "night_float" and
        MapSet.member?(triggers, {r.schedule_resident.schedule_id, day}) and
          not Enum.any?(
            Map.get(facts, key, []),
            &("night_float" in &1.targets or "strong_weekend_nights" in &1.targets)
          ) ->
        "post_call"

      true ->
        r.rotation_type
    end
  end
end
