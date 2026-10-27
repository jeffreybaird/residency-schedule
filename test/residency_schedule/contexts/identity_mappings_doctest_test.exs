defmodule ResidencySchedule.IdentityMappingsDoctestTest do
  use ResidencySchedule.DataCase

  alias ResidencySchedule.DetailedSchedules.ActivitySource
  alias ResidencySchedule.IdentityMappingDoctestFixtures
  alias ResidencySchedule.IdentityMappings
  alias ResidencySchedule.IdentityMappings.{Backfill, Crosswalk, Resolver}

  doctest Backfill
  doctest Crosswalk
  doctest Resolver
  doctest ResidencySchedule.Release

  @documented_functions [
    {IdentityMappings,
     [normalize_key: 2, resolve: 3, prepare_crosswalk: 4, approve_crosswalk: 2, backfill: 1]},
    {Backfill, [run: 1]},
    {Crosswalk, [prepare: 4, approve: 2]},
    {Resolver, [resolve: 3, evaluate: 3, exact_candidates: 2, identity: 1]},
    {IdentityMappings.Key, [normalize: 2, valid_literal?: 1, fold: 1]},
    {IdentityMappings.State,
     [
       admin: 2,
       roster: 1,
       mappings: 2,
       snapshot: 1,
       target_status: 2,
       review_state: 2,
       next_revision: 3
     ]},
    {ResidencySchedule.Release, [backfill_identity_mappings: 0]}
  ]

  test "every new public identity function provides an executable usage example" do
    missing =
      for {module, functions} <- @documented_functions,
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

  test "explicit doctest source fixture has real scoped data and no implicit approvals" do
    ctx = IdentityMappingDoctestFixtures.with_source()
    assert {:ok, [member]} = IdentityMappings.State.roster(ctx.schedule.id)
    assert member.id == ctx.member.id

    assert Repo.get!(ActivitySource, ctx.source.id).raw_staff ==
             "Legacy Iris"

    assert IdentityMappings.State.mappings(ctx.schedule.id, :qgenda) == []
  end
end
