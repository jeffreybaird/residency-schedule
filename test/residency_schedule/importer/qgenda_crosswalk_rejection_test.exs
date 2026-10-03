defmodule ResidencySchedule.Importer.QgendaCrosswalkRejectionTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest

  alias ResidencySchedule.Importer.QgendaPreview
  alias ResidencySchedule.{Residents, Schedules}

  @header "academic_year,position_code,qgenda_staff,existing_name\n"
  @valid @header <> "2026,R2-2,\"Vale, Juniper\",Juniper Vail\n"

  setup do
    previous = Application.fetch_env(:residency_schedule, :qgenda_crosswalk_path)

    path =
      Path.join(System.tmp_dir!(), "qgenda-rejected-#{System.unique_integer([:positive])}.csv")

    File.write!(path, @valid)
    Application.put_env(:residency_schedule, :qgenda_crosswalk_path, path)

    on_exit(fn ->
      File.rm(path)

      case previous do
        {:ok, value} -> Application.put_env(:residency_schedule, :qgenda_crosswalk_path, value)
        :error -> Application.delete_env(:residency_schedule, :qgenda_crosswalk_path)
      end
    end)

    {:ok, schedule} = Schedules.upsert_schedule(2026, "2026–2027")

    for {name, number} <- [{"Iris Reed", 1}, {"Juniper Vail", 2}] do
      {:ok, _} =
        Residents.insert_resident(schedule.id, %{
          name: name,
          position_code: "R2-#{number}",
          residency_year: 2,
          schedule_number: number
        })
    end

    :ok
  end

  test "a stale uploaded identity cannot fall through to an exact full-name match" do
    csv = @header <> "2026,R2-1,\"Reed, Iris\",Stale Name\n"

    assert {:error, _} =
             QgendaPreview.prepare(workbook(), academic_year: 2026, crosswalk_csv: csv)
  end

  test "case or name-order variants cannot claim separate residents" do
    for raw <- ["VALE, JUNIPER", "Juniper Vale"] do
      csv = @valid <> "2026,R2-1,\"#{raw}\",Iris Reed\n"

      assert {:error, _} =
               QgendaPreview.prepare(workbook(), academic_year: 2026, crosswalk_csv: csv)
    end
  end

  describe "rejected optional uploads" do
    setup :admin_authenticate_session

    test "oversized crosswalk never silently falls back to configured names", %{conn: conn} do
      assert_rejected_upload(conn, "reviewed.csv", String.duplicate("x", 1_000_001))
    end

    test "unsupported extension never silently falls back to configured names", %{conn: conn} do
      assert_rejected_upload(conn, "reviewed.exe", @valid)
    end
  end

  test "an unfinished CSV upload cannot be treated as an absent optional file", %{conn: conn} do
    %{conn: conn} = admin_authenticate_session(%{conn: conn})
    {:ok, view, _} = live(conn, "/admin/upload")
    view |> form("#qgenda-upload-form", %{"academic_year" => "2026"}) |> render_change()

    partial =
      file_input(view, "#qgenda-upload-form", :qgenda_crosswalk_csv, [
        %{
          name: "reviewed.csv",
          content: @valid,
          type: "text/csv"
        }
      ])

    render_upload(partial, "reviewed.csv", 50)

    file =
      file_input(view, "#qgenda-upload-form", :qgenda_xlsx, [
        %{
          name: "schedule.xlsx",
          content: workbook(),
          type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        }
      ])

    render_upload(file, "schedule.xlsx")
    render_click(view, "qgenda-preview", %{"academic_year" => "2026"})
    assert has_element?(view, "#qgenda-error")
    refute has_element?(view, "#qgenda-preview")
  end

  defp assert_rejected_upload(conn, name, content) do
    before = Residents.list_residents()
    {:ok, view, _} = live(conn, "/admin/upload")
    view |> form("#qgenda-upload-form", %{"academic_year" => "2026"}) |> render_change()

    invalid =
      file_input(view, "#qgenda-upload-form", :qgenda_crosswalk_csv, [
        %{
          name: name,
          content: content,
          type: if(Path.extname(name) == ".csv", do: "text/csv", else: "application/octet-stream")
        }
      ])

    render_upload(invalid, name)
    assert has_element?(view, "#qgenda-crosswalk-help p.text-red-600")

    workbook =
      file_input(view, "#qgenda-upload-form", :qgenda_xlsx, [
        %{
          name: "schedule.xlsx",
          content: workbook(),
          type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        }
      ])

    render_upload(workbook, "schedule.xlsx")
    view |> form("#qgenda-upload-form", %{"academic_year" => "2026"}) |> render_submit()
    assert has_element?(view, "#qgenda-error")
    refute has_element?(view, "#qgenda-preview")
    assert Residents.list_residents() == before
  end

  defp workbook, do: File.read!("test/fixtures/qgenda/shared.xlsx")
end
