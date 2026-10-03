defmodule ResidencyScheduleWeb.QgendaUploadTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest

  alias ResidencySchedule.{Repo, Residents, Schedules}

  setup do
    {:ok, schedule} = Schedules.upsert_schedule(2026, "2026–2027")

    for {name, index} <- [{"Iris Reed", 1}, {"Parker Missing", 2}] do
      {:ok, _} =
        Residents.insert_resident(schedule.id, %{
          name: name,
          position_code: "R2-#{index}",
          residency_year: 2,
          schedule_number: index
        })
    end

    :ok
  end

  test "QGenda upload remains admin-only", %{conn: conn} do
    assert get(conn, "/admin/upload") |> redirected_to() == "/login"
    %{conn: resident_conn} = authenticate_session(%{conn: conn})
    assert {:error, {:redirect, _}} = live(resident_conn, "/admin/upload")
  end

  describe "admin preview" do
    setup :admin_authenticate_session

    test "renders a separate preview form while preserving CSV upload", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/upload")
      assert has_element?(view, "form[phx-submit='save'] input[type='file']")
      assert has_element?(view, "#qgenda-upload-form input[type='file']")

      assert has_element?(
               view,
               "#qgenda-upload-form select[name='academic_year'] option[value='2026']"
             )
    end

    test "previews source details, notes, unknown tasks and missing residents without writes", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, "/admin/upload")
      before = snapshot()
      upload(view)
      assert has_element?(view, "#qgenda-preview")
      assert has_element?(view, "#qgenda-summary")
      assert has_element?(view, "#qgenda-coverage", "2027-01-04")
      assert has_element?(view, "#qgenda-missing-residents", "Parker Missing")
      assert has_element?(view, "#qgenda-unknown-tasks", "Mystery Service")

      assert has_element?(
               view,
               "#qgenda-assignments [data-qgenda-assignment]",
               "GOG Continuity Clinic PM"
             )

      assert has_element?(view, "#qgenda-assignments", "Bring simulation kit")
      refute has_element?(view, "#qgenda-preview button", "Confirm and Import")
      assert snapshot() == before
      # Forged legacy confirmation is harmless while the preview has no CSV review.
      render_click(view, "confirm", %{})
      assert snapshot() == before
      assert has_element?(view, "#qgenda-preview")
    end

    test "a repeated upload replaces the preview instead of appending rows", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/upload")
      upload(view)
      first = view |> element("#qgenda-assignments") |> render()
      upload(view)
      assert view |> element("#qgenda-assignments") |> render() == first
      assert has_element?(view, "#qgenda-summary")
    end

    test "filters on linked notes and can clear the filter", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/upload")
      upload(view)
      view |> form("#qgenda-filter-form", %{"query" => "Bring simulation kit"}) |> render_change()
      assert has_element?(view, "#qgenda-assignments [data-source-cell='D6']")
      refute has_element?(view, "#qgenda-assignments [data-source-cell='B6']")
      view |> form("#qgenda-filter-form", %{"query" => ""}) |> render_change()
      assert has_element?(view, "#qgenda-assignments [data-source-cell='B6']")
    end

    test "bounded pages expose assignments beyond the first hundred", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/upload")
      upload(view, File.read!("test/fixtures/qgenda/paginated.xlsx"))

      rows =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#qgenda-assignments [data-qgenda-assignment]")
        |> Enum.count()

      assert rows > 0 and rows <= 100
      refute has_element?(view, "#qgenda-assignments", "Final Synthetic Service")
      view |> element("#qgenda-next-page") |> render_click()
      assert has_element?(view, "#qgenda-assignments", "Final Synthetic Service")
    end

    test "malformed workbook shows an error without damaging the existing schedule", %{conn: conn} do
      {:ok, view, _} = live(conn, "/admin/upload")
      before = snapshot()
      upload(view, "broken archive")
      assert has_element?(view, "#qgenda-error")
      refute has_element?(view, "#qgenda-preview")
      assert snapshot() == before
    end
  end

  defp upload(view, binary \\ File.read!("test/fixtures/qgenda/shared.xlsx")) do
    view |> form("#qgenda-upload-form", %{"academic_year" => "2026"}) |> render_change()

    file =
      file_input(view, "#qgenda-upload-form", :qgenda_xlsx, [
        %{
          name: "schedule.xlsx",
          content: binary,
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
