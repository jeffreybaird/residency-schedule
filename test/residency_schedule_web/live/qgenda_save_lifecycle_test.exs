defmodule ResidencyScheduleWeb.QgendaSaveLifecycleTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest
  import ResidencySchedule.QgendaDetailFixtures
  alias ResidencySchedule.DetailedSchedules
  alias ResidencySchedule.Importer.QgendaPreview

  setup :admin_authenticate_session

  setup ctx do
    data = seed_detail_roster()
    {:ok, preview} = detail_preview()
    Map.merge(data, %{preview: preview, admin: ctx.user})
  end

  test "corrected crosswalk saves newly resolved identities from the same workbook", ctx do
    {:ok, unresolved} =
      QgendaPreview.prepare(detail_workbook(), academic_year: 2026)

    {:ok, first} = DetailedSchedules.commit(unresolved, ctx.admin)
    assert first.inserted == 6
    assert DetailedSchedules.list_for_resident(ctx.juniper.id, ~D[2026-12-30]) == []
    assert {:ok, second} = DetailedSchedules.commit(ctx.preview, ctx.admin)
    assert second.batch_id == first.batch_id
    assert second.inserted == 2
    assert second.existing == 6
    assert DetailedSchedules.list_for_resident(ctx.juniper.id, ~D[2026-12-30]) |> length() == 1
  end

  test "canceling preview clears its save candidate", ctx do
    {:ok, view, _} = live(ctx.conn, "/admin/upload")
    upload_preview(view)
    view |> element("#qgenda-cancel-preview") |> render_click()
    refute has_element?(view, "#qgenda-save-preview")
    render_click(view, "qgenda-save", %{})
    assert DetailedSchedules.list_for_date(ctx.schedule.id, ~D[2026-12-29]) == []
  end

  test "changing academic year invalidates the previous save candidate", ctx do
    {:ok, _} = ResidencySchedule.Schedules.upsert_schedule(2025, "2025–2026")
    {:ok, view, _} = live(ctx.conn, "/admin/upload")
    upload_preview(view)
    view |> form("#qgenda-upload-form", %{"academic_year" => "2025"}) |> render_change()
    refute has_element?(view, "#qgenda-save-preview")
    render_click(view, "qgenda-save", %{})
    assert DetailedSchedules.list_for_date(ctx.schedule.id, ~D[2026-12-29]) == []
  end

  test "an already imported source occurrence cannot be remapped to another resident", ctx do
    {:ok, _} = DetailedSchedules.commit(ctx.preview, ctx.admin)
    before = DetailedSchedules.list_for_resident(ctx.juniper.id, ~D[2026-12-30])

    {:ok, other} =
      ResidencySchedule.Residents.insert_resident(ctx.schedule.id, %{
        name: "Alternate Resident",
        position_code: "R2-4",
        residency_year: 2,
        schedule_number: 4
      })

    {:ok, remapped} =
      QgendaPreview.prepare(detail_workbook(),
        academic_year: 2026,
        aliases: %{
          "Vale, Juniper" => %{position_code: "R2-4", expected_name: "Alternate Resident"}
        }
      )

    assert {:error, _} = DetailedSchedules.commit(remapped, ctx.admin)
    assert DetailedSchedules.list_for_resident(other.id, ~D[2026-12-30]) == []
    assert DetailedSchedules.list_for_resident(other.id, ~D[2027-01-02]) == []
    assert DetailedSchedules.list_for_resident(ctx.juniper.id, ~D[2026-12-30]) == before
  end

  defp upload_preview(view, binary \\ detail_workbook()) do
    view |> form("#qgenda-upload-form", %{"academic_year" => "2026"}) |> render_change()

    file =
      file_input(view, "#qgenda-upload-form", :qgenda_xlsx, [
        %{
          name: "detail.xlsx",
          content: binary,
          type: "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet"
        }
      ])

    render_upload(file, "detail.xlsx")
    view |> form("#qgenda-upload-form", %{"academic_year" => "2026"}) |> render_submit()
  end
end
