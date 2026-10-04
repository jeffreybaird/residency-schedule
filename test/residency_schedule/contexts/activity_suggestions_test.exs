defmodule ResidencySchedule.ActivitySuggestionsTest do
  use ResidencySchedule.DataCase
  import ResidencySchedule.ActivitySearchFixtures
  alias ResidencySchedule.{DetailedSchedules, Residents, Schedules}
  alias ResidencySchedule.DetailedSchedules.Activity

  setup do
    seed_activity_search()
  end

  test "suggestions are distinct literal task labels, excluding notes and names" do
    assert {:ok, labels} = suggestions(%{query: "CLINIC"})
    assert labels == ["GOG Continuity Clinic AM", "GOG Continuity Clinic PM"]
    assert {:ok, []} = suggestions(%{query: "simulation"})
    assert {:ok, []} = suggestions(%{query: "Iris Reed"})
    assert {:ok, []} = suggestions(%{query: "Page 1"})
  end

  test "percent, underscore and backslash are literal substrings", ctx do
    insert_labels(ctx.iris.id, [
      "Literal 100% Clinic",
      "Literal clinic_A",
      "Literal C:\\Room",
      "Literal clinicXA"
    ])

    assert {:ok, ["Literal 100% Clinic"]} = suggestions(%{query: "%"})
    assert {:ok, ["Literal clinic_A"]} = suggestions(%{query: "_"})
    assert {:ok, ["Literal C:\\Room"]} = suggestions(%{query: "\\"})
  end

  test "labels respect selected academic year, stable person and inclusive dates", ctx do
    {:ok, prior} = Schedules.upsert_schedule(2025, "2025–2026")

    {:ok, prior_person} =
      Residents.insert_resident(prior.id, %{
        name: "Iris Reed",
        resident_id: ctx.iris.resident_id,
        position_code: "R1-1",
        residency_year: 1,
        schedule_number: 1
      })

    insert_labels(prior_person.id, ["Prior Clinic"], ~D[2025-12-29])
    assert {:ok, ["Prior Clinic"]} = suggestions(%{academic_year: 2025, query: "clinic"})

    assert {:ok, ["GOG Continuity Clinic PM"]} =
             suggestions(%{
               query: "clinic",
               resident_id: ctx.iris.resident_id,
               start_date: "2026-12-29",
               end_date: "2026-12-29"
             })

    assert {:ok, []} = suggestions(%{query: "clinic", resident_id: ctx.stone.resident_id})
  end

  test "blank suggestions are deterministically sorted and limited before hydration", ctx do
    insert_labels(
      ctx.iris.id,
      Enum.map(1..25, &("A Task " <> String.pad_leading(to_string(&1), 2, "0")))
    )

    owner = self()
    handler = "activity-suggestions-#{System.unique_integer([:positive])}"

    :telemetry.attach(
      handler,
      [:residency_schedule, :repo, :query],
      fn _, _, metadata, _ ->
        send(owner, {:suggestion_sql, metadata.query})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, labels} = suggestions(%{query: ""})
    assert labels == Enum.map(1..20, &("A Task " <> String.pad_leading(to_string(&1), 2, "0")))
    queries = collect_queries([])
    task_queries = Enum.filter(queries, &String.contains?(&1, "detailed_activities"))
    assert length(task_queries) == 1
    [sql] = task_queries
    assert sql =~ "DISTINCT"
    assert sql =~ "LIMIT"
    refute sql =~ "activity_sources"
  end

  test "invalid filters return errors rather than suggestions from a wider scope" do
    for params <- [
          %{},
          %{academic_year: 9999},
          %{academic_year: 2026, query: %{}},
          %{academic_year: 2026, query: String.duplicate("x", 201)},
          %{academic_year: 2026, resident_id: %{}},
          %{academic_year: 2026, start_date: "bad"},
          %{academic_year: 2026, start_date: "2027-01-03", end_date: "2026-12-28"}
        ] do
      assert {:error, message} = DetailedSchedules.activity_suggestions(params)
      assert is_binary(message)
    end
  end

  defp suggestions(params),
    do: DetailedSchedules.activity_suggestions(Map.put_new(params, :academic_year, 2026))

  defp insert_labels(schedule_resident_id, labels, date \\ ~D[2026-12-29]) do
    Enum.each(labels, fn label ->
      Repo.insert!(%Activity{
        schedule_resident_id: schedule_resident_id,
        date: date,
        raw_task: label
      })
    end)
  end

  defp collect_queries(queries) do
    receive do
      {:suggestion_sql, query} -> collect_queries([query | queries])
    after
      0 -> Enum.reverse(queries)
    end
  end
end
