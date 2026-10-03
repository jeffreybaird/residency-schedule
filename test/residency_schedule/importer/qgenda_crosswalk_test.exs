defmodule ResidencySchedule.Importer.QgendaCrosswalkTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest

  alias ResidencySchedule.Importer.QgendaPreview
  alias ResidencySchedule.{Residents, Schedules}

  doctest ResidencySchedule.Importer.QgendaWorkbook
  doctest ResidencySchedule.Importer.QgendaParser
  doctest ResidencySchedule.Importer.QgendaPreview

  @header "academic_year,position_code,qgenda_staff,existing_name\n"

  setup do
    previous = Application.fetch_env(:residency_schedule, :qgenda_crosswalk_path)

    path =
      Path.join(System.tmp_dir!(), "qgenda-crosswalk-#{System.unique_integer([:positive])}.csv")

    Application.put_env(:residency_schedule, :qgenda_crosswalk_path, path)

    on_exit(fn ->
      File.rm(path)

      case previous do
        {:ok, value} -> Application.put_env(:residency_schedule, :qgenda_crosswalk_path, value)
        :error -> Application.delete_env(:residency_schedule, :qgenda_crosswalk_path)
      end
    end)

    {:ok, schedule} = Schedules.upsert_schedule(2026, "2026–2027")

    {:ok, resident} =
      Residents.insert_resident(schedule.id, %{
        name: "Juniper Vail",
        position_code: "R2-2",
        residency_year: 2,
        schedule_number: 2
      })

    %{crosswalk_path: path, resident: resident}
  end

  test "configured reviewed CSV matches the selected year's position and prior name", context do
    write_crosswalk(context, "2026,R2-2,\"Vale, Juniper\",Juniper Vail\n")
    assert {:ok, preview} = preview()
    match = juniper(preview)
    assert match.resident_id == context.resident.resident_id
    assert match.display_name == "Juniper Vale"
    assert match.previous_name == "Juniper Vail"
    assert match.status == :matched
    assert preview.warnings == []
  end

  test "crosswalk rows for another academic year cannot link the current roster", context do
    write_crosswalk(context, "2025,R2-2,\"Vale, Juniper\",Juniper Vail\n")
    assert {:ok, preview} = preview()
    assert juniper(preview).resident_id == nil
    assert juniper(preview).status == :unmatched
  end

  test "stale expected names and missing positions cannot authorize a link", context do
    for row <- [
          "2026,R2-2,\"Vale, Juniper\",Different Person\n",
          "2026,R2-9,\"Vale, Juniper\",Juniper Vail\n"
        ] do
      write_crosswalk(context, row)
      assert {:ok, preview} = preview()
      assert juniper(preview).resident_id == nil
    end
  end

  test "conflicting reviewed rows never use first or last row wins", context do
    write_crosswalk(
      context,
      "2026,R2-2,\"Vale, Juniper\",Juniper Vail\n2026,R2-9,\"Vale, Juniper\",Other Person\n"
    )

    assert {:ok, preview} = preview()
    assert juniper(preview).resident_id == nil
  end

  test "missing or malformed configured files produce a warning and a safe unmatched preview",
       context do
    for content <- [nil, "", "wrong,headers\n2026,unexpected\n", @header <> "2026,R2-2\n"] do
      if content,
        do: File.write!(context.crosswalk_path, content),
        else: File.rm(context.crosswalk_path)

      assert {:ok, preview} = preview()
      assert juniper(preview).resident_id == nil
      assert preview.warnings != []
    end
  end

  test "admin upload uses configured crosswalk without mutating the person's old name", context do
    write_crosswalk(context, "2026,R2-2,\"Vale, Juniper\",Juniper Vail\n")
    %{conn: conn} = admin_authenticate_session(context)
    {:ok, view, _} = live(conn, "/admin/upload")
    view |> form("#qgenda-upload-form", %{"academic_year" => "2026"}) |> render_change()

    upload =
      file_input(view, "#qgenda-upload-form", :qgenda_xlsx, [
        %{
          name: "schedule.xlsx",
          content: workbook(),
          type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        }
      ])

    render_upload(upload, "schedule.xlsx")
    view |> form("#qgenda-upload-form", %{"academic_year" => "2026"}) |> render_submit()
    assert has_element?(view, "#qgenda-assignments", "Juniper Vale")
    assert has_element?(view, "#qgenda-assignments", "Juniper Vail")
    assert Enum.any?(Residents.list_residents(), &(&1.name == "Juniper Vail"))
    refute Enum.any?(Residents.list_residents(), &(&1.name == "Juniper Vale"))
  end

  defp write_crosswalk(context, rows), do: File.write!(context.crosswalk_path, @header <> rows)
  defp preview, do: QgendaPreview.prepare(workbook(), academic_year: 2026)
  defp workbook, do: File.read!("test/fixtures/qgenda/shared.xlsx")
  defp juniper(preview), do: Enum.find(preview.matches, &(&1.raw_staff == "Vale, Juniper"))
end
