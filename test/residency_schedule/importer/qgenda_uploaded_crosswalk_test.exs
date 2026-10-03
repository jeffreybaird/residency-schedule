defmodule ResidencySchedule.Importer.QgendaUploadedCrosswalkTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest

  alias ResidencySchedule.Importer.QgendaPreview
  alias ResidencySchedule.{Repo, Residents, Schedules}

  @header "academic_year,position_code,qgenda_staff,existing_name\n"
  @row "2026,R2-2,\"Vale, Juniper\",Juniper Vail\n"

  setup do
    original = Application.fetch_env(:residency_schedule, :qgenda_crosswalk_path)
    path = Path.join(System.tmp_dir!(), "qgenda-upload-#{System.unique_integer([:positive])}.csv")
    Application.put_env(:residency_schedule, :qgenda_crosswalk_path, path)

    on_exit(fn ->
      File.rm(path)

      case original do
        {:ok, value} -> Application.put_env(:residency_schedule, :qgenda_crosswalk_path, value)
        :error -> Application.delete_env(:residency_schedule, :qgenda_crosswalk_path)
      end
    end)

    {:ok, schedule} = Schedules.upsert_schedule(2026, "2026–2027")

    {:ok, person} =
      Residents.insert_resident(schedule.id, %{
        name: "Juniper Vail",
        position_code: "R2-2",
        residency_year: 2,
        schedule_number: 2
      })

    %{crosswalk_path: path, person: person}
  end

  test "uploaded crosswalk matches a verified roster identity and labels its source", context do
    before = snapshot()
    assert {:ok, result} = prepare(@header <> @row)
    assert result.crosswalk_source == :uploaded
    assert match(result).resident_id == context.person.resident_id
    assert match(result).display_name == "Juniper Vale"
    assert match(result).previous_name == "Juniper Vail"
    assert result.warnings == []
    assert snapshot() == before
  end

  test "configured fallback and unavailable source are explicit", context do
    assert {:ok, missing} = QgendaPreview.prepare(workbook(), academic_year: 2026)
    assert missing.crosswalk_source == :unavailable
    assert missing.warnings != []
    File.write!(context.crosswalk_path, @header <> @row)
    assert {:ok, configured} = QgendaPreview.prepare(workbook(), academic_year: 2026)
    assert configured.crosswalk_source == :configured
    assert match(configured).resident_id == context.person.resident_id
  end

  test "uploaded crosswalk replaces configured aliases for that preview only", context do
    File.write!(context.crosswalk_path, @header <> @row)
    stale = @header <> String.replace(@row, "Juniper Vail", "Stale Name")
    assert {:ok, uploaded} = prepare(stale)
    assert uploaded.crosswalk_source == :uploaded
    assert match(uploaded).resident_id == nil
    assert uploaded.warnings != []
    assert {:ok, fallback} = QgendaPreview.prepare(workbook(), academic_year: 2026)
    assert fallback.crosswalk_source == :configured
    assert match(fallback).resident_id == context.person.resident_id
  end

  test "strict schema rejects malformed headers, short rows, blank identities and wrong years" do
    for csv <- [
          "",
          "wrong,headers\nvalue,value\n",
          @header <> "2026,R2-2\n",
          "academic_year,position_code,qgenda_staff,existing_name,existing_name\n2026,R2-2,\"Vale, Juniper\",Juniper Vail,Other\n",
          @header <> "2026,R2-2,,Juniper Vail\n",
          @header <> "2026,,\"Vale, Juniper\",Juniper Vail\n",
          @header <> "2026,R2-2,\"Vale, Juniper\",\n",
          @header <> String.replace(@row, "2026", "2025")
        ] do
      assert {:error, message} = prepare(csv)
      assert is_binary(message)
    end
  end

  test "extra columns and malformed quotes are rejected" do
    for csv <- [
          "academic_year,position_code,qgenda_staff,existing_name,extra\n2026,R2-2,\"Vale, Juniper\",Juniper Vail,ignored\n",
          @header <> "2026,R2-2,\"Vale, Juniper,Juniper Vail\n"
        ] do
      assert {:error, _} = prepare(csv)
    end
  end

  test "duplicate or conflicting raw staff mappings are rejected rather than first or last wins" do
    for rows <- [@row <> @row, @row <> "2026,R2-3,\"Vale, Juniper\",Other Person\n"] do
      assert {:error, _} = prepare(@header <> rows)
    end
  end

  test "distinct staff cannot claim the same roster position" do
    assert {:error, _} = prepare(@header <> @row <> "2026,R2-2,\"Other, Person\",Juniper Vail\n")
  end

  test "a crosswalk contradicting an exact full-name match is rejected" do
    schedule = Schedules.get_by_year(2026)

    {:ok, _} =
      Residents.insert_resident(schedule.id, %{
        name: "Iris Reed",
        position_code: "R2-1",
        residency_year: 2,
        schedule_number: 1
      })

    assert {:error, _} = prepare(@header <> "2026,R2-2,\"Reed, Iris\",Juniper Vail\n")
  end

  test "stale names and unknown positions stay unmatched with warnings" do
    for row <- [
          String.replace(@row, "Juniper Vail", "Stale Name"),
          String.replace(@row, "R2-2", "R2-9")
        ] do
      assert {:ok, result} = prepare(@header <> row)
      assert match(result).resident_id == nil
      assert result.warnings != []
    end
  end

  test "crosswalk byte limit applies before CSV processing" do
    assert {:error, _} = prepare(String.duplicate("x", 1_000_001))
  end

  describe "optional upload" do
    setup :admin_authenticate_session

    test "admin can preview with CSV names without changing persisted records", context do
      {:ok, view, _} = live(context.conn, "/admin/upload")
      assert has_element?(view, "#qgenda-crosswalk-help")
      before = snapshot()
      upload(view, @header <> @row)
      assert has_element?(view, "#qgenda-crosswalk-source", "Uploaded")
      assert has_element?(view, "#qgenda-assignments [data-source-cell='F6']", "Juniper Vale")
      assert has_element?(view, "#qgenda-assignments [data-source-cell='F6']", "matched")
      refute has_element?(view, "#qgenda-missing-residents", "Juniper Vail")
      assert snapshot() == before
    end

    test "uploaded mapping does not leak into a later preview or another session", context do
      {:ok, view, _} = live(context.conn, "/admin/upload")
      upload(view, @header <> @row)
      upload(view)
      assert has_element?(view, "#qgenda-crosswalk-source", "Unavailable")
      assert has_element?(view, "#qgenda-missing-residents", "Juniper Vail")
      {:ok, fresh, _} = live(context.conn, "/admin/upload")
      upload(fresh)
      assert has_element?(fresh, "#qgenda-crosswalk-source", "Unavailable")
      assert has_element?(fresh, "#qgenda-missing-residents", "Juniper Vail")
    end

    test "XLSX-only preview continues to use configured crosswalk", context do
      File.write!(context.crosswalk_path, @header <> @row)
      {:ok, view, _} = live(context.conn, "/admin/upload")
      upload(view)
      assert has_element?(view, "#qgenda-crosswalk-source", "Configured")
      refute has_element?(view, "#qgenda-missing-residents", "Juniper Vail")
    end

    test "invalid uploaded crosswalk shows an error with no stale preview or DB write", context do
      {:ok, view, _} = live(context.conn, "/admin/upload")
      upload(view, @header <> @row)
      before = snapshot()
      upload(view, "invalid csv")
      assert has_element?(view, "#qgenda-error")
      refute has_element?(view, "#qgenda-preview")
      assert snapshot() == before
    end
  end

  defp prepare(csv),
    do: QgendaPreview.prepare(workbook(), academic_year: 2026, crosswalk_csv: csv)

  defp workbook, do: File.read!("test/fixtures/qgenda/shared.xlsx")
  defp match(result), do: Enum.find(result.matches, &(&1.raw_staff == "Vale, Juniper"))

  defp upload(view, csv \\ nil) do
    view |> form("#qgenda-upload-form", %{"academic_year" => "2026"}) |> render_change()

    if csv do
      mapping =
        file_input(view, "#qgenda-upload-form", :qgenda_crosswalk_csv, [
          %{
            name: "reviewed.csv",
            content: csv,
            type: "text/csv"
          }
        ])

      render_upload(mapping, "reviewed.csv")
    end

    file =
      file_input(view, "#qgenda-upload-form", :qgenda_xlsx, [
        %{
          name: "schedule.xlsx",
          content: workbook(),
          type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        }
      ])

    render_upload(file, "schedule.xlsx")
    view |> form("#qgenda-upload-form", %{"academic_year" => "2026"}) |> render_submit()
  end

  defp snapshot do
    for schema <- [
          ResidencySchedule.Residents.Resident,
          ResidencySchedule.Residents.ScheduleResident,
          ResidencySchedule.Rotations.Rotation,
          ResidencySchedule.Schedules.Schedule
        ],
        into: %{},
        do: {schema, Repo.all(schema)}
  end
end
