defmodule ResidencyScheduleWeb.PreferredActivityNamesTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest
  import ResidencySchedule.QgendaDetailFixtures
  alias ResidencySchedule.{DetailedSchedules, ResidentDisplayNames, Residents, Schedules}
  alias ResidencySchedule.Importer.QgendaPreview

  doctest ResidencySchedule.ResidentDisplayNames

  setup :authenticate_session

  setup do
    data = seed_detail_roster()
    admin = ResidencySchedule.ScheduleFixtures.admin_user()
    {:ok, original} = detail_preview()
    {:ok, _} = DetailedSchedules.commit(original, admin)
    {:ok, next_year} = Schedules.upsert_schedule(2027, "2027–2028")

    {:ok, _} =
      Residents.insert_resident(next_year.id, %{
        name: "Juniper Vail",
        resident_id: data.juniper.resident_id,
        position_code: "R3-2",
        residency_year: 3,
        schedule_number: 2
      })

    updated =
      mutate_detail_workbook("xl/sharedStrings.xml", fn xml ->
        xml
        |> String.replace("2027", "2028")
        |> String.replace("2026", "2027")
        |> String.replace("Vale, Juniper", "Vale-Smith, Juniper")
      end)

    {:ok, newer} =
      QgendaPreview.prepare(updated,
        academic_year: 2027,
        aliases: %{
          "Vale-Smith, Juniper" => %{position_code: "R3-2", expected_name: "Juniper Vail"}
        }
      )

    {:ok, _} = DetailedSchedules.commit(newer, admin)
    data
  end

  test "old activity presents the current person name while its original source remains unchanged",
       ctx do
    [activity] = DetailedSchedules.list_for_resident(ctx.juniper.id, ~D[2026-12-30])
    assert activity.display_name == "Juniper Vale-Smith"
    assert activity.raw_staff == "Vale, Juniper"
    assert Enum.all?(activity.sources, &(&1.display_name == "Juniper Vale"))
    assert Enum.all?(activity.sources, &(&1.raw_staff == "Vale, Juniper"))
  end

  test "calendar old-year activity and resident panel use the newer imported name", ctx do
    {:ok, calendar, _} = live(ctx.conn, "/calendar?view=day&date=2026-12-30")

    assert has_element?(
             calendar,
             "#day-activities [data-resident-id='#{ctx.juniper.resident_id}']",
             "Juniper Vale-Smith"
           )

    {:ok, resident, _} = live(ctx.conn, "/residents/#{ctx.juniper.id}")
    assert has_element?(resident, "h1", "Juniper Vale-Smith")
    resident |> form("#resident-activity-date-form", %{"date" => "2026-12-30"}) |> render_change()
    assert has_element?(resident, "#resident-day-activities", "Juniper Vale-Smith")
  end

  test "case-only imported variants retain existing full-name capitalization without changing spelling",
       ctx do
    names = ResidentDisplayNames.names_for_people([ctx.iris.resident_id])
    assert names[ctx.iris.resident_id] == "Iris Reed"

    assert ResidentDisplayNames.name_for(7, "Morgan McDonald", %{7 => "MORGAN MCDONALD"}) ==
             "Morgan McDonald"

    assert ResidentDisplayNames.name_for(7, "Juniper Vail", %{7 => "Juniper Vale"}) ==
             "Juniper Vale"
  end

  test "nested entry presentation handles missing and nil residents without changing identity",
       ctx do
    entries = [%{resident: ctx.juniper, covered_by: nil}, %{original_resident: ctx.juniper}, %{}]
    [first, second, empty] = ResidentDisplayNames.apply_to_entries(entries)
    assert first.resident.name == "Juniper Vale-Smith"
    assert first.resident.resident_id == ctx.juniper.resident_id
    assert first.covered_by == nil
    assert second.original_resident.name == "Juniper Vale-Smith"
    assert empty == %{}
    assert ResidentDisplayNames.apply_to_entries([]) == []
  end
end
