defmodule ResidencySchedule.EffectiveSchedule.Policies.SaturdayHighlandGap do
  @moduledoc "Version 1 retained-context resolution with the named Highland Saturday exception."

  @doc """
  Resolves targets from base services or the explicit Saturday policy.

      iex> fact = %{targets: ["highland_night_float", "highland_weekend_nights"], policy: "highland_saturday_gap_v1", activity: %{date: ~D[2026-11-07]}}
      iex> ResidencySchedule.EffectiveSchedule.Policies.SaturdayHighlandGap.resolve(fact, [])
      {"highland_weekend_nights", nil}
  """
  def resolve(%{targets: [code]}, _bases), do: {code, nil}
  def resolve(%{targets: []}, _bases), do: {"qgenda_assignment", nil}

  def resolve(fact, bases) do
    matching =
      bases |> Enum.map(& &1.rotation_type) |> Enum.filter(&(&1 in fact.targets)) |> Enum.uniq()

    cond do
      length(matching) == 1 ->
        {hd(matching), nil}

      highland_saturday?(fact) ->
        {"highland_weekend_nights", nil}

      insufficient_friday_policy?(fact, bases) ->
        {"qgenda_assignment", :insufficient_policy_evidence}

      true ->
        {"qgenda_assignment", :context_required}
    end
  end

  defp highland_saturday?(fact),
    do:
      fact.policy == "highland_saturday_gap_v1" and
        Enum.sort(fact.targets) == ["highland_night_float", "highland_weekend_nights"] and
        Date.day_of_week(fact.activity.date) == 6

  defp insufficient_friday_policy?(fact, bases),
    do:
      Date.day_of_week(fact.activity.date) == 5 and
        "ambulatory" in Enum.map(bases, & &1.rotation_type) and
        Enum.sort(fact.targets) == ["night_float", "strong_weekend_nights"] and
        fact.policy != "friday_strong_correction_v1"
end
