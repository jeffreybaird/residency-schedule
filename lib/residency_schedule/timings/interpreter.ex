defmodule ResidencySchedule.Timings.Interpreter do
  @moduledoc """
  Pure interpretation of how precisely one source occurrence states its time.

  The caller's date is kept literally; a period label never establishes hours
  and instants are only accepted as supplied, in one zone, with the end after
  the start. Nothing here reads or writes the database.
  """

  @rule_version "legacy_timing_v1"
  @periods ["AM", "PM", "Day", "Night"]

  @doc """
  Interprets stored timing facts into one precision outcome.

      iex> {:ok, result} =
      ...>   ResidencySchedule.Timings.Interpreter.interpret(%{date: ~D[2026-12-30], period: "PM"})
      iex> {result.precision, result.period, result.policy, result.starts_at}
      {:period, "PM", "stored_period", nil}

      iex> ResidencySchedule.Timings.Interpreter.interpret(%{date: ~D[2026-12-30], period: "Evening"})
      {:error, :unsupported_period}
  """
  def interpret(facts) when is_map(facts) do
    with {:ok, date} <- fetch_date(facts) do
      facts
      |> instants()
      |> interpret_shape(date, Map.get(facts, :period))
    end
  end

  def interpret(_facts), do: {:error, :invalid_date}

  defp fetch_date(%{date: %Date{} = date}), do: {:ok, date}
  defp fetch_date(_facts), do: {:error, :invalid_date}

  defp instants(facts), do: {Map.get(facts, :starts_at), Map.get(facts, :ends_at)}

  defp interpret_shape({nil, nil}, date, nil), do: {:ok, date_only(date)}

  defp interpret_shape({nil, nil}, date, period) when period in @periods,
    do: {:ok, stored_period(date, period)}

  defp interpret_shape({nil, nil}, _date, _period), do: {:error, :unsupported_period}

  defp interpret_shape({starts_at, ends_at}, date, nil) do
    if exact_instants?(starts_at, ends_at),
      do: {:ok, exact(date, starts_at, ends_at)},
      else: {:error, :invalid_instants}
  end

  defp interpret_shape(_instants, _date, _period), do: {:error, :invalid_instants}

  defp exact_instants?(%DateTime{} = starts_at, %DateTime{} = ends_at) do
    starts_at.time_zone == ends_at.time_zone and DateTime.compare(starts_at, ends_at) == :lt
  end

  defp exact_instants?(_starts_at, _ends_at), do: false

  defp date_only(date) do
    result(date, :date_only, nil, nil, nil, nil, "date_only")
  end

  defp stored_period(date, period) do
    result(date, :period, period, nil, nil, nil, "stored_period")
  end

  defp exact(date, starts_at, ends_at) do
    result(date, :exact, nil, starts_at, ends_at, starts_at.time_zone, "exact_source")
  end

  defp result(date, precision, period, starts_at, ends_at, time_zone, policy) do
    %{
      source_date: date,
      precision: precision,
      period: period,
      starts_at: starts_at,
      ends_at: ends_at,
      time_zone: time_zone,
      rule_version: @rule_version,
      policy: policy
    }
  end
end
