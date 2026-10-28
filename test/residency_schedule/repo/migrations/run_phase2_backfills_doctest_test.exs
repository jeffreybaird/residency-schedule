defmodule ResidencySchedule.Repo.Migrations.RunPhase2BackfillsDoctestTest do
  use ResidencySchedule.DataCase

  alias ResidencySchedule.Repo.Migrations.RunPhase2Backfills

  # The migration is compiled with docs onto the code path once by
  # test/test_helper.exs (ResidencySchedule.MigrationDoctests), so `doctest`
  # can read its documentation here.
  doctest RunPhase2Backfills

  test "the one-shot backfill migration documents an executable usage example" do
    public_functions = [{RunPhase2Backfills, [run: 0]}]

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
