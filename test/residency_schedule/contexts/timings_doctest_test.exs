defmodule ResidencySchedule.TimingsDoctestTest do
  use ResidencySchedule.DataCase

  alias ResidencySchedule.Release
  alias ResidencySchedule.Timings
  alias ResidencySchedule.Timings.{Backfill, Interpreter}

  doctest Timings
  doctest Interpreter
  doctest Backfill
  doctest Release, only: [backfill_timings: 0]

  test "every new public timing function documents an executable usage example" do
    public_functions = [
      {Timings, [interpret: 1, backfill: 1]},
      {Interpreter, [interpret: 1]},
      {Backfill, [run: 1]},
      {Release, [backfill_timings: 0]}
    ]

    missing =
      for {module, functions} <- public_functions,
          {:docs_v1, _, _, _, _, _, docs} = Code.fetch_docs(module),
          {name, arity} <- functions,
          not Enum.any?(docs, fn
            {{:function, ^name, ^arity}, _, _, %{"en" => text}, _} ->
              Regex.match?(~r/^\s*iex(?:\(\d+\))?>/m, text)

            _ ->
              false
          end),
          do: {module, name, arity}

    assert missing == [], "Missing executable examples: #{inspect(missing)}"
  end
end
