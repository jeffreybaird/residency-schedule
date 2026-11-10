defmodule ResidencySchedule.EffectiveSchedule.Policies.NightBoundary do
  @moduledoc "Version 1 night-boundary geometry over retained target evidence."
  alias ResidencySchedule.Rotations.HighlandPostCall

  @doc """
  Projects canonical night blocks onto their evening dates.

      iex> rotation = %{id: 1, schedule_resident_id: 2, rotation_type: "night_float", start_date: ~D[2026-11-02], end_date: ~D[2026-11-06], source_assignment_date: nil}
      iex> [night, post_call] = ResidencySchedule.EffectiveSchedule.Policies.NightBoundary.apply([rotation], [], [])
      iex> {night.start_date, night.end_date, post_call.rotation_type}
      {~D[2026-11-01], ~D[2026-11-05], "post_call"}
  """
  def apply(rotations, facts, overrides) do
    rotations = HighlandPostCall.normalize(rotations)
    by_id = Map.new(rotations, &{&1.id, &1})
    by_resident = Enum.group_by(rotations, & &1.schedule_resident_id)

    protected =
      overrides
      |> Enum.flat_map(&protected_dates(&1, by_id))
      |> Map.new()

    fridays =
      rotations
      |> Enum.filter(&canonical?(&1, "night_float", 1, 4))
      |> MapSet.new(&{&1.schedule_resident_id, &1.end_date})

    explicit =
      facts
      |> Enum.filter(
        &("night_float" in &1.targets and
            MapSet.member?(fridays, {&1.activity.schedule_resident_id, &1.activity.date}))
      )
      |> MapSet.new(&{&1.activity.schedule_resident_id, &1.activity.date})

    projected =
      rotations
      |> Enum.flat_map(&project(&1, Map.fetch!(by_resident, &1.schedule_resident_id), explicit))
      |> Enum.flat_map(fn r ->
        r.start_date
        |> Date.range(r.end_date)
        |> Enum.chunk_by(&retained?(r, &1, protected, explicit))
        |> Enum.filter(&retained?(r, hd(&1), protected, explicit))
        |> Enum.map(&%{r | start_date: hd(&1), end_date: List.last(&1)})
      end)

    present =
      projected
      |> Enum.flat_map(fn r ->
        for d <- Date.range(r.start_date, r.end_date), do: {r.schedule_resident_id, d}
      end)
      |> MapSet.new()

    restored =
      protected
      |> Enum.reject(fn {key, _} -> MapSet.member?(present, key) end)
      |> Enum.map(fn {{_, day}, r} -> %{r | start_date: day, end_date: day} end)

    Enum.sort_by(projected ++ restored, & &1.start_date, Date)
  end

  defp protected_dates(o, by_id) do
    case Map.get(by_id, o.rotation_id) do
      nil ->
        []

      r ->
        for day <- Date.range(o.override_start_date, o.override_end_date),
            do: {{r.schedule_resident_id, day}, r}
    end
  end

  defp canonical?(r, type, weekday, duration),
    do:
      r.rotation_type == type and Date.day_of_week(r.start_date) == weekday and
        Date.diff(r.end_date, r.start_date) == duration

  defp neighbor?(r, rotations, field, date, type, weekday, duration),
    do:
      Enum.any?(
        rotations,
        &(&1.schedule_resident_id == r.schedule_resident_id and Map.fetch!(&1, field) == date and
            canonical?(&1, type, weekday, duration))
      )

  defp project(r, rotations, explicit) do
    cond do
      canonical?(r, "night_float", 1, 4) ->
        [shift_night(r) | night_tail(r, rotations, explicit)]

      canonical?(r, "strong_weekend_nights", 6, 1) and
          neighbor?(r, rotations, :end_date, Date.add(r.start_date, -1), "ambulatory", 1, 4) ->
        [shift_night(r)]

      canonical?(r, "ambulatory", 1, 4) and
          neighbor?(
            r,
            rotations,
            :start_date,
            Date.add(r.end_date, 1),
            "strong_weekend_nights",
            6,
            1
          ) ->
        [%{r | end_date: Date.add(r.end_date, -1)}]

      canonical?(r, "post_call", 6, 1) and
          adjacent_night_float?(r, rotations) ->
        [shift(r)]

      true ->
        [r]
    end
  end

  defp adjacent_night_float?(r, rotations),
    do:
      neighbor?(r, rotations, :end_date, Date.add(r.start_date, -1), "night_float", 1, 4) or
        neighbor?(r, rotations, :start_date, Date.add(r.end_date, 1), "night_float", 1, 4)

  defp night_tail(r, rotations, explicit) do
    cond do
      MapSet.member?(explicit, {r.schedule_resident_id, r.end_date}) ->
        [%{r | start_date: r.end_date, source_assignment_date: r.end_date}]

      Enum.any?(
        rotations,
        &(&1.rotation_type == "post_call" and r.end_date in Date.range(&1.start_date, &1.end_date))
      ) ->
        []

      neighbor?(r, rotations, :start_date, Date.add(r.end_date, 1), "post_call", 6, 1) ->
        []

      true ->
        [%{r | start_date: r.end_date, rotation_type: "post_call"}]
    end
  end

  defp shift(r),
    do: %{r | start_date: Date.add(r.start_date, -1), end_date: Date.add(r.end_date, -1)}

  defp shift_night(r), do: r |> shift() |> then(&%{&1 | source_assignment_date: &1.start_date})

  defp retained?(r, day, protected, explicit) do
    case Map.get(protected, {r.schedule_resident_id, day}) do
      nil ->
        r.rotation_type != "post_call" or
          not MapSet.member?(explicit, {r.schedule_resident_id, day})

      original ->
        original.id == r.id and original.rotation_type == r.rotation_type
    end
  end
end
