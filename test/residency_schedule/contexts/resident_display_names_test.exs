defmodule ResidencySchedule.ResidentDisplayNamesTest do
  use ResidencySchedule.DataCase
  import ResidencySchedule.QgendaDetailFixtures
  alias ResidencySchedule.{DetailedSchedules, Repo, ResidentDisplayNames, Residents, Schedules}
  alias ResidencySchedule.Importer.QgendaPreview

  setup do
    data = seed_detail_roster()
    {:ok, preview} = detail_preview()
    admin = ResidencySchedule.ScheduleFixtures.admin_user()
    {:ok, _} = DetailedSchedules.commit(preview, admin)
    Map.put(data, :admin, admin)
  end

  test "imported names follow the stable person across academic years without DB renaming", ctx do
    {:ok, prior} = Schedules.upsert_schedule(2025, "2025–2026")

    {:ok, earlier} =
      Residents.insert_resident(prior.id, %{
        name: "Juniper Vail",
        resident_id: ctx.juniper.resident_id,
        position_code: "R1-2",
        residency_year: 1,
        schedule_number: 2
      })

    names = ResidentDisplayNames.names_for_people([ctx.juniper.resident_id])
    assert names[ctx.juniper.resident_id] == "Juniper Vale"
    [current, old] = ResidentDisplayNames.apply_to_schedule_residents([ctx.juniper, earlier])
    assert current.name == "Juniper Vale"
    assert old.name == "Juniper Vale"
    assert current.resident_id == old.resident_id

    assert Repo.get!(ResidencySchedule.Residents.Resident, ctx.juniper.resident_id).name ==
             "Juniper Vail"

    assert Residents.list_residents_for_schedule(ctx.schedule.id)
           |> Enum.find(&(&1.id == ctx.juniper.id))
           |> Map.fetch!(:name) == "Juniper Vail"
  end

  test "unimported same-first-name resident keeps their own name and Last, First is displayed correctly",
       ctx do
    {:ok, other} =
      Residents.insert_resident(ctx.schedule.id, %{
        name: "Other, Juniper",
        position_code: "R2-4",
        residency_year: 2,
        schedule_number: 4
      })

    [imported, fallback] = ResidentDisplayNames.apply_to_schedule_residents([ctx.juniper, other])
    assert imported.name == "Juniper Vale"
    assert fallback.name == "Juniper Other"

    refute Map.has_key?(
             ResidentDisplayNames.names_for_people([other.resident_id]),
             other.resident_id
           )

    assert ResidentDisplayNames.names_for_people([]) == %{}
    assert ResidentDisplayNames.apply_to_schedule_residents([]) == []
  end

  test "latest source within the latest academic year wins deterministically", ctx do
    renamed =
      mutate_detail_workbook(
        "xl/sharedStrings.xml",
        &String.replace(&1, "Vale, Juniper", "Vale-Smith, Juniper")
      )

    {:ok, newer} =
      QgendaPreview.prepare(renamed,
        academic_year: 2026,
        aliases: %{
          "Vale-Smith, Juniper" => %{position_code: "R2-2", expected_name: "Juniper Vail"}
        }
      )

    {:ok, _} = DetailedSchedules.commit(newer, ctx.admin)

    assert ResidentDisplayNames.names_for_people([ctx.juniper.resident_id])[
             ctx.juniper.resident_id
           ] == "Juniper Vale-Smith"

    {:ok, prior} = Schedules.upsert_schedule(2025, "2025–2026")

    {:ok, _} =
      Residents.insert_resident(prior.id, %{
        name: "Juniper Vail",
        resident_id: ctx.juniper.resident_id,
        position_code: "R1-2",
        residency_year: 1,
        schedule_number: 2
      })

    historic =
      mutate_detail_workbook("xl/sharedStrings.xml", fn xml ->
        xml
        |> String.replace("2026", "2025")
        |> String.replace("2027", "2026")
        |> String.replace("Vale, Juniper", "Historic, Juniper")
      end)

    {:ok, earlier} =
      QgendaPreview.prepare(historic,
        academic_year: 2025,
        aliases: %{
          "Historic, Juniper" => %{position_code: "R1-2", expected_name: "Juniper Vail"}
        }
      )

    {:ok, _} = DetailedSchedules.commit(earlier, ctx.admin)

    assert ResidentDisplayNames.names_for_people([ctx.juniper.resident_id])[
             ctx.juniper.resident_id
           ] == "Juniper Vale-Smith"
  end

  test "a roster resolves imported names in a batch rather than once per row", ctx do
    recipient = self()
    handler = {__MODULE__, make_ref()}

    :ok =
      :telemetry.attach(
        handler,
        [:residency_schedule, :repo, :query],
        fn _, _, metadata, _ ->
          if String.starts_with?(metadata.query, "SELECT"),
            do: send(recipient, {:name_query, metadata.query})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    rows = ResidentDisplayNames.apply_to_schedule_residents(List.duplicate(ctx.juniper, 40))
    assert length(rows) == 40
    assert Enum.all?(rows, &(&1.name == "Juniper Vale"))
    assert length(queries()) == 1
  end

  defp queries do
    receive do
      {:name_query, query} -> [query | queries()]
    after
      0 -> []
    end
  end
end
