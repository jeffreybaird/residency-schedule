defmodule ResidencySchedule.TaskMappingsDoctestTest do
  use ResidencySchedule.DataCase

  alias ResidencySchedule.TaskMappings
  alias ResidencySchedule.TaskMappings.{Backfill, Classifier, Key, Legacy}

  doctest TaskMappings
  doctest Backfill
  doctest Classifier
  doctest Key
  doctest Legacy

  doctest ResidencySchedule.Importer.CsvParser,
    only: [rotation_abbreviations: 0, normalize_task_label: 1]

  doctest ResidencySchedule.Importer.QgendaPreview, only: [known_tasks: 0]
  doctest ResidencySchedule.DetailedSchedules.TaskEquivalence, only: [equivalences: 0]
  doctest ResidencySchedule.Release, only: [backfill_task_classifications: 0]

  test "every new public task mapping function documents an executable usage example" do
    public_functions = [
      {TaskMappings, [normalize_key: 2, seed_legacy: 0, classify: 2, backfill: 1]},
      {Backfill, [run: 1]},
      {Classifier, [classify: 2, targets: 1, snapshot: 1]},
      {Key, [normalize: 2]},
      {Legacy, [seed: 0]},
      {ResidencySchedule.Importer.CsvParser,
       [rotation_abbreviations: 0, normalize_task_label: 1]},
      {ResidencySchedule.Importer.QgendaPreview, [known_tasks: 0]},
      {ResidencySchedule.DetailedSchedules.TaskEquivalence, [equivalences: 0]},
      {ResidencySchedule.Release, [backfill_task_classifications: 0]}
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
