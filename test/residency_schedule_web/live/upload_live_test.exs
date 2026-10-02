defmodule ResidencyScheduleWeb.UploadLiveTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest

  alias ResidencySchedule.Importer.ScheduleImporter

  describe "unauthenticated access" do
    test "redirects to /login when not logged in", %{conn: conn} do
      conn = get(conn, "/admin/upload")
      assert redirected_to(conn) == "/login"
    end
  end

  describe "upload page" do
    setup %{conn: conn} do
      %{conn: conn} = admin_authenticate_session(%{conn: conn})
      {:ok, view, html} = live(conn, "/admin/upload")
      %{view: view, html: html}
    end

    test "renders Upload Schedule heading", %{html: html} do
      assert html =~ "Upload Schedule"
    end

    test "renders Import Schedule submit button", %{html: html} do
      assert html =~ "Import Schedule"
    end

    test "renders Back to Admin link", %{html: html} do
      assert html =~ "Back to Admin"
    end

    test "shows error when save submitted with no file", %{view: view} do
      html = view |> element("form[phx-submit='save']") |> render_submit()
      assert html =~ "Please select a CSV file"
    end
  end

  describe "review step" do
    setup %{conn: conn} do
      seed_schedule()
      %{conn: conn} = admin_authenticate_session(%{conn: conn})
      {:ok, view, _html} = live(conn, "/admin/upload")
      %{view: view}
    end

    defp upload_and_submit(view, fixture) do
      file =
        file_input(view, "form[phx-submit='save']", :schedule_csv, [
          %{name: Path.basename(fixture), content: File.read!(fixture), type: "text/csv"}
        ])

      render_upload(file, Path.basename(fixture))
      view |> element("form[phx-submit='save']") |> render_submit()
    end

    test "shows proposed links and writes nothing until confirmed", %{view: view} do
      html = upload_and_submit(view, "test/fixtures/schedule_2024_2025.csv")

      assert html =~ "Confirm Residents"
      assert html =~ "2024–2025"
      assert html =~ "Exact name"
      assert html =~ "No match"
      assert has_element?(view, "#link-review select[name='link[R4-1]']")
      assert ResidencySchedule.Schedules.get_by_year(2024) == nil
    end

    test "warns when the year already exists", %{view: view} do
      html = upload_and_submit(view, "test/fixtures/sample.csv")
      assert html =~ "already exists and will be replaced"
    end

    test "confirming imports with the proposed links", %{view: view} do
      people_before = ResidencySchedule.Residents.list_residents()
      upload_and_submit(view, "test/fixtures/schedule_2024_2025.csv")

      view |> form("form[phx-submit='confirm']") |> render_submit()

      schedule = ResidencySchedule.Schedules.get_by_year(2024)
      assert schedule != nil
      assert_redirect(view, "/?schedule_id=#{schedule.id}")

      person_ids =
        schedule.id
        |> ResidencySchedule.Residents.list_residents_for_schedule()
        |> Enum.map(& &1.resident_id)

      # Continuing residents kept their person record; first-years were created.
      assert Enum.any?(person_ids, &(&1 in Enum.map(people_before, fn p -> p.id end)))
      assert length(ResidencySchedule.Residents.list_residents()) > length(people_before)
    end

    test "an admin override links a row to the chosen person", %{view: view} do
      fixture = "test/fixtures/schedule_2024_2025.csv"
      {:ok, prepared} = ScheduleImporter.prepare(File.read!(fixture))
      unmatched = Enum.find(prepared.proposals, &(&1.confidence == :none))
      # Briar graduates after 2023, so linking an unmatched 2024 row to them is a free choice.
      briar = ResidencySchedule.Residents.get_resident_by_position!("R4-1")
      upload_and_submit(view, fixture)

      view
      |> form("form[phx-submit='confirm']", %{
        "link" => %{unmatched.position_code => to_string(briar.resident_id)}
      })
      |> render_submit()

      schedule = ResidencySchedule.Schedules.get_by_year(2024)
      assert schedule != nil

      linked =
        schedule.id
        |> ResidencySchedule.Residents.list_residents_for_schedule()
        |> Enum.find(&(&1.position_code == unmatched.position_code))

      assert linked.resident_id == briar.resident_id
    end

    test "a rejected choice writes nothing and stays selected for correction", %{view: view} do
      fixture = "test/fixtures/schedule_2024_2025.csv"
      {:ok, prepared} = ScheduleImporter.prepare(File.read!(fixture))
      matched = Enum.find(prepared.proposals, &(&1.confidence == :exact))
      upload_and_submit(view, fixture)

      html =
        view
        |> form("form[phx-submit='confirm']", %{"link" => %{matched.position_code => "new"}})
        |> render_submit()

      assert html =~ "already exists"
      assert ResidencySchedule.Schedules.get_by_year(2024) == nil

      assert has_element?(
               view,
               "select[name='link[#{matched.position_code}]'] option[value='new'][selected]"
             )
    end

    test "cancel returns to the upload form", %{view: view} do
      upload_and_submit(view, "test/fixtures/schedule_2024_2025.csv")
      html = view |> element("button[phx-click='cancel-review']") |> render_click()
      assert html =~ "Upload Schedule"
      refute html =~ "Confirm Residents"
    end
  end
end
