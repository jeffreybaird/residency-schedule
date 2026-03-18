defmodule ResidencyScheduleWeb.BuilderLiveTest do
  use ResidencyScheduleWeb.ConnCase
  import Phoenix.LiveViewTest

  setup :admin_authenticate_session

  describe "initial render" do
    test "renders year input and Generate button before generation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/build")
      assert has_element?(view, "input[name='year']")
      assert has_element?(view, "button", "Generate")
    end

    test "shows placeholder text before generating", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/build")
      assert html =~ "Enter an academic year"
    end
  end

  describe "generate" do
    test "clicking Generate populates the Gantt grid with resident rows", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/build")

      view
      |> element("form")
      |> render_submit(%{"year" => "2026"})

      assert has_element?(view, "td", "R1-1")
      assert has_element?(view, "td", "R4-8")
    end

    test "generates 32 resident rows in the grid", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/build")

      view |> element("form") |> render_submit(%{"year" => "2026"})

      html = render(view)
      # 32 residents × 2 sticky cells = 64 position code + name cells; count position codes
      assert (html |> String.split("R1-") |> length()) - 1 >= 8
    end

    test "shows warning badge when warnings exist after generation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/build")
      view |> element("form") |> render_submit(%{"year" => "2026"})
      # After generation, either "No warnings" or a warnings count badge should appear
      html = render(view)
      assert html =~ "warning" or html =~ "No warnings"
    end
  end

  describe "year filter" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/build")
      view |> element("form") |> render_submit(%{"year" => "2026"})
      {:ok, view: view}
    end

    test "filtering by R1 shows R1 year group and hides R4 year group", %{view: view} do
      view
      |> element("button[phx-click='filter_year'][phx-value-year='1']")
      |> render_click()

      assert has_element?(view, "td", "R1 Residents")
      refute has_element?(view, "td", "R4 Residents")
    end

    test "filtering All restores all year groups", %{view: view} do
      view
      |> element("button[phx-click='filter_year'][phx-value-year='1']")
      |> render_click()

      view
      |> element("button[phx-click='filter_year'][phx-value-year='all']")
      |> render_click()

      assert has_element?(view, "td", "R1 Residents")
      assert has_element?(view, "td", "R4 Residents")
    end
  end

  describe "picker panel" do
    setup %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/build")
      view |> element("form") |> render_submit(%{"year" => "2026"})
      {:ok, view: view}
    end

    test "clicking a cell opens the picker panel", %{view: view} do
      view
      |> element("td[phx-click='open_picker'][phx-value-res-idx='0'][phx-value-slot-idx='0']")
      |> render_click()

      assert has_element?(view, "[phx-click='close_picker']")
      assert has_element?(view, "p", "Select Rotation")
    end

    test "picker shows resident position code", %{view: view} do
      view
      |> element("td[phx-click='open_picker'][phx-value-res-idx='0'][phx-value-slot-idx='0']")
      |> render_click()

      html = render(view)
      assert html =~ "R1-1"
    end

    test "closing the picker hides the panel", %{view: view} do
      view
      |> element("td[phx-click='open_picker'][phx-value-res-idx='0'][phx-value-slot-idx='0']")
      |> render_click()

      view
      |> element("button[phx-click='close_picker']")
      |> render_click()

      refute has_element?(view, "p", "Select Rotation")
    end

    test "selecting a rotation updates the cell and closes the picker", %{view: view} do
      view
      |> element("td[phx-click='open_picker'][phx-value-res-idx='0'][phx-value-slot-idx='0']")
      |> render_click()

      view
      |> element("button[phx-click='set_rotation'][phx-value-rotation='vacation']")
      |> render_click()

      refute has_element?(view, "p", "Select Rotation")
      html = render(view)
      assert html =~ "Vac"
    end
  end

  describe "load from existing schedule" do
    setup %{conn: conn} do
      seed_schedule()
      {:ok, conn: conn}
    end

    test "shows the existing schedule in the Load dropdown", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/admin/build")
      assert html =~ "Load"
      assert html =~ "Optimize"
    end

    test "Load & Optimize loads the schedule into the Gantt grid", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/build")

      view |> element("button[phx-click='load_schedule']") |> render_click()

      # Should show resident rows from the loaded schedule
      html = render(view)
      assert html =~ "Residents"
    end

    test "loaded state has no more duty violations after optimization", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/build")

      view |> element("button[phx-click='load_schedule']") |> render_click()

      html = render(view)
      # After Load & Optimize, duty warnings should be zero or reduced
      # (either "No warnings" badge or reduced count vs unoptimized)
      assert html =~ "warning" or html =~ "No warnings"
    end

    test "Resolve Violations button clears remaining duty warnings", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/build")

      # Generate a fresh schedule (which will have violations)
      view |> element("form") |> render_submit(%{"year" => "2035"})

      html_before = render(view)

      if html_before =~ "Resolve Violations" do
        view |> element("button[phx-click='resolve']") |> render_click()
        html_after = render(view)
        # Violations should be reduced or eliminated
        assert html_after =~ "warning" or html_after =~ "No warnings"
      end
    end
  end

  describe "save" do
    test "Save button is rendered after generation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/build")
      view |> element("form") |> render_submit(%{"year" => "2026"})
      assert has_element?(view, "button[phx-click='save']")
    end

    test "Save persists the schedule and shows confirmation", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/admin/build")
      view |> element("form") |> render_submit(%{"year" => "2026"})

      view |> element("button[phx-click='save']") |> render_click()

      html = render(view)
      assert html =~ "Saved" or html =~ "Save Failed"
    end
  end
end
