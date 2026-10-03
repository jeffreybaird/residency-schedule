defmodule ResidencySchedule.ActivitySearchTest do
  use ResidencySchedule.DataCase
  import ResidencySchedule.ActivitySearchFixtures

  import ResidencySchedule.QgendaDetailFixtures,
    only: [detail_preview: 1, mutate_detail_workbook: 2]

  alias ResidencySchedule.{DetailedSchedules, Residents, Schedules}
  alias ResidencySchedule.Importer.QgendaPreview

  setup do
    seed_activity_search()
  end

  test "searches case-insensitive task and note text with neutral result fields" do
    assert {:ok, tasks} = search(%{query: "cOnTiNuItY cLiNiC"})
    assert tasks.total == 3
    assert {:ok, notes} = search(%{query: "SIMULATION KIT"})
    assert notes.total == 1
    [activity] = notes.entries
    assert activity.raw_task == "GOG Continuity Clinic PM"
    assert activity.date == ~D[2026-12-29]
    assert activity.period == "PM"
    assert activity.site == "GOG"
    assert Enum.any?(activity.notes, &String.contains?(&1, "Bring simulation kit"))

    for key <- [:sources, :raw_staff, :previous_name, :batch_id, :source_cell, :source_sheet] do
      refute Map.has_key?(activity, key)
    end
  end

  test "percent, underscore and backslash are literal substrings rather than wildcards" do
    for query <- ["%", "_", "\\", "clinic_A", "C:\\Room"] do
      assert {:ok, result} = search(%{query: query})
      assert result.total == 1
      assert hd(result.entries).raw_task == "GOG Continuity Clinic PM"
    end

    for query <- ["Page 1", "A15"] do
      assert {:ok, result} = search(%{query: query})
      assert result.total == 0
    end
  end

  test "canonical and legacy resident names find the same person without borrowing another first-name match",
       ctx do
    for query <- ["Juniper Vale", "juniper vail"] do
      assert {:ok, result} = search(%{query: query})
      assert result.total == 2

      assert Enum.all?(
               result.entries,
               &(&1.resident_id == ctx.juniper.resident_id and &1.display_name == "Juniper Vale")
             )
    end

    assert {:ok, iris} = search(%{query: "Iris", resident_id: ctx.stone.resident_id})
    assert iris.total == 1
    assert hd(iris.entries).raw_task == "Mystery Service"
  end

  test "newer imported names remain searchable for the same person's earlier-year activities",
       ctx do
    {:ok, later} = Schedules.upsert_schedule(2027, "2027–2028")

    {:ok, _} =
      Residents.insert_resident(later.id, %{
        name: "Juniper Vail",
        resident_id: ctx.juniper.resident_id,
        position_code: "R3-2",
        residency_year: 3,
        schedule_number: 2
      })

    binary =
      mutate_detail_workbook("xl/sharedStrings.xml", fn xml ->
        xml
        |> String.replace("2027", "2028")
        |> String.replace("2026", "2027")
        |> String.replace("Vale, Juniper", "Vale-Smith, Juniper")
      end)

    {:ok, preview} =
      QgendaPreview.prepare(binary,
        academic_year: 2027,
        aliases: %{
          "Vale-Smith, Juniper" => %{position_code: "R3-2", expected_name: "Juniper Vail"}
        }
      )

    {:ok, _} = DetailedSchedules.commit(preview, ctx.admin)
    assert {:ok, result} = search(%{query: "Juniper Vale-Smith"})
    assert result.total == 2

    assert Enum.all?(
             result.entries,
             &(&1.schedule_resident_id == ctx.juniper.id and
                 &1.display_name == "Juniper Vale-Smith")
           )
  end

  test "date bounds are inclusive and resident filtering uses stable person identity", ctx do
    assert {:ok, result} =
             search(%{
               start_date: ~D[2026-12-29],
               end_date: ~D[2026-12-29],
               resident_id: ctx.iris.resident_id
             })

    assert result.total == 2

    assert Enum.all?(
             result.entries,
             &(&1.date == ~D[2026-12-29] and &1.resident_id == ctx.iris.resident_id)
           )

    {:ok, other} = Schedules.upsert_schedule(2025, "2025–2026")

    assert {:ok, empty} =
             DetailedSchedules.search(%{
               academic_year: other.academic_year,
               resident_id: ctx.iris.resident_id
             })

    assert empty.entries == []
    assert {:ok, unknown} = search(%{resident_id: 2_147_483_647})
    assert unknown.entries == []
    assert unknown.total == 0
  end

  test "pagination is bounded, stable, and counts activities once despite multiple matching sources",
       ctx do
    binary =
      mutate_detail_workbook(
        "xl/sharedStrings.xml",
        &String.replace(&1, "Bring simulation kit", "Bring simulation kit again")
      )

    {:ok, preview} = detail_preview(binary)
    {:ok, _} = DetailedSchedules.commit(preview, ctx.admin)
    assert {:ok, matching} = search(%{query: "simulation kit"})
    assert matching.total == 1

    pages =
      Enum.map(1..3, fn page ->
        assert {:ok, result} = search(%{page: page, page_size: 3})
        assert result.total == 8
        assert result.page == page
        assert result.page_size == 3
        result.entries
      end)

    assert Enum.map(pages, &length/1) == [3, 3, 2]
    ids = pages |> List.flatten() |> Enum.map(& &1.id)
    assert length(Enum.uniq(ids)) == 8
    assert {:ok, again} = search(%{page: 1, page_size: 3})
    assert Enum.map(again.entries, & &1.id) == Enum.take(ids, 3)
    assert {:ok, defaults} = search(%{})
    assert defaults.page_size == 50
  end

  test "invalid and excessive filters return errors rather than widening the search" do
    for params <- [
          %{academic_year: 9999},
          %{academic_year: "invalid"},
          %{query: String.duplicate("x", 201)},
          %{start_date: "invalid"},
          %{start_date: ~D[2027-01-02], end_date: ~D[2026-12-29]},
          %{start_date: ~D[2020-01-01]},
          %{end_date: ~D[2030-01-01]},
          %{page: 0},
          %{page: 10_001},
          %{page: "invalid"},
          %{page_size: 101},
          %{page_size: 0},
          %{resident_id: "invalid"}
        ] do
      assert {:error, reason} = search(params)
      assert is_binary(reason)
    end
  end

  test "only the requested page is hydrated with a fixed query budget" do
    recipient = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:residency_schedule, :repo, :query],
        fn _, _, metadata, _ ->
          if String.starts_with?(metadata.query, "SELECT"),
            do: send(recipient, {:search_query, metadata.query})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    assert {:ok, page} = search(%{page_size: 1})
    assert length(page.entries) == 1
    queries = queries()
    assert length(queries) <= 8

    assert Enum.any?(
             queries,
             &(String.contains?(&1, "detailed_activities") and String.contains?(&1, "LIMIT"))
           )
  end

  defp search(params), do: DetailedSchedules.search(Map.merge(%{academic_year: 2026}, params))

  defp queries do
    receive do
      {:search_query, sql} -> [sql | queries()]
    after
      0 -> []
    end
  end
end
