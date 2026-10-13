defmodule ResidencyScheduleWeb.ScheduleRenderUpdatesTest do
  use ResidencyScheduleWeb.ConnCase, async: false

  alias Phoenix.LiveView.{Diff, Renderer, Utils}
  alias Phoenix.LiveViewTest.Diff, as: ClientDiff
  alias ResidencySchedule.ScheduleFixtures
  alias ResidencyScheduleWeb.{Endpoint, ScheduleLive.Index}

  setup do
    previous = Application.get_env(:residency_schedule, :current_date)
    Application.put_env(:residency_schedule, :current_date, ~D[2026-07-10])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:residency_schedule, :current_date, previous),
        else: Application.delete_env(:residency_schedule, :current_date)
    end)

    set_demo_mode(false)
    data = ScheduleFixtures.seed_mini_schedule()
    earlier = ScheduleFixtures.seed_prior_year_for_clare(data)
    user = create_admin("render-test-password")

    socket = %Phoenix.LiveView.Socket{
      view: Index,
      transport_pid: self(),
      endpoint: Endpoint,
      private: %{live_layout: false, live_temp: %{}},
      assigns: %{__changed__: %{}, current_user: user}
    }

    {:ok, mounted} = Index.mount(%{}, %{}, socket)
    {state, _} = render_state({mounted, Diff.new_fingerprints(), Diff.new_components(), %{}})
    [row_path] = dynamic_paths(elem(state, 3), "<tbody>")
    %{state: state, row_path: row_path, data: data, earlier: earlier}
  end

  test "initial grid preserves every row, slot, cell identity and column width", %{state: state} do
    socket = elem(state, 0)
    html = html(state)
    document = LazyHTML.from_fragment(html)

    assert length(
             LazyHTML.query(document, "#gantt-scroll th[data-slot-aca-year]")
             |> LazyHTML.to_tree()
           ) == length(socket.assigns.all_slots)

    assert names(state) == ["Clare", "Mary", "Tiff"]

    for {_count, cell} <- Enum.flat_map(socket.assigns.unified_residents, & &1.cells),
        rotation <- rotations(cell) do
      assert LazyHTML.query(document, "#gantt-pill-#{rotation.cell_id}")
             |> LazyHTML.attribute("phx-value-cell-id") == [rotation.cell_id]
    end

    assert LazyHTML.query(document, "#gantt-scroll tbody [data-tour-resident-name]")
           |> LazyHTML.attribute("style")
           |> Enum.uniq() == ["width: 148px; min-width: 148px; max-width: 148px"]
  end

  test "forced unchanged rendering emits no diff", %{state: state} do
    {next, diff} = render_state(state)
    assert diff == %{}
    assert html(next) == html(state)
  end

  test "All year navigation preserves grid without resending its rows", %{
    state: state,
    row_path: path
  } do
    {changed, diff} = event(state, "view_academic_year", %{"aca_year" => "2025"})
    assert elem(changed, 0).assigns.viewed_aca_year == 2025
    assert diff == %{}
    assert_no_rows(diff, path)
    assert grid(changed) == grid(state)
    {filtered, _} = event(changed, "filter_year", %{"year" => "2"})
    assert names(filtered) == ["Tiff"]
  end

  test "resident filter and viewed year update exactly the matching cohort", %{state: state} do
    {filtered, diff} = event(state, "filter_year", %{"year" => "2"})
    assert diff != %{}
    assert names(filtered) == ["Clare", "Mary"]
    {previous_year, _} = event(filtered, "view_academic_year", %{"aca_year" => "2025"})
    assert names(previous_year) == ["Tiff"]
    {all, _} = event(previous_year, "filter_year", %{"year" => "all"})
    assert names(all) == ["Clare", "Mary", "Tiff"]
    assert grid(all) == grid(state)
  end

  test "modal open and close change only modal content and preserve return focus", %{
    state: state,
    row_path: path
  } do
    token = first_token(state)
    {opened, open_diff} = event(state, "open_rotation_details", %{"cell-id" => token})
    assert_no_rows(open_diff, path)
    assert grid(opened) == grid(state)
    document = LazyHTML.from_fragment(html(opened))

    assert LazyHTML.query(document, "#gantt-rotation-modal") |> LazyHTML.attribute("role") == [
             "dialog"
           ]

    [focus] =
      LazyHTML.query(document, "#gantt-rotation-modal") |> LazyHTML.attribute("phx-remove")

    assert focus =~ "#gantt-pill-#{token}"

    assert LazyHTML.query(document, "#gantt-close-details") |> LazyHTML.attribute("id") == [
             "gantt-close-details"
           ]

    {closed, close_diff} = event(opened, "close_rotation_details", %{})
    assert_no_rows(close_diff, path)
    assert html(closed) == html(state)
    {_unchanged, diff} = event(closed, "close_rotation_details", %{})
    assert diff == %{}
  end

  test "scroll closes the modal and retains the existing navigation payload", %{
    state: state,
    row_path: path,
    data: data
  } do
    {opened, _} = event(state, "open_rotation_details", %{"cell-id" => first_token(state)})

    {scrolled, diff} =
      event(opened, "scroll_to_schedule", %{"id" => Integer.to_string(data.schedule.id)})

    assert_no_rows(diff, path)
    assert elem(scrolled, 0).assigns.rotation_modal == nil

    assert diff[:e] == [
             ["scroll-to-schedule", %{schedule_id: Integer.to_string(data.schedule.id)}]
           ]

    assert grid(scrolled) == grid(state)
  end

  test "deletion refresh resets filtering and updates grid through the empty state", %{
    state: state,
    data: data,
    earlier: earlier
  } do
    {filtered, _} = event(state, "filter_year", %{"year" => "2"})

    {deleted, _} =
      event(filtered, "delete_schedule", %{
        "schedule_id" => Integer.to_string(data.schedule.id),
        "password" => "render-test-password"
      })

    assert elem(deleted, 0).assigns.filter_year == nil
    assert names(deleted) == ["Clare"]

    assert Enum.all?(
             elem(deleted, 0).assigns.all_slots,
             &(elem(&1, 0) == earlier.prior_schedule.id)
           )

    {empty, _} =
      event(deleted, "delete_schedule", %{
        "schedule_id" => Integer.to_string(earlier.prior_schedule.id),
        "password" => "render-test-password"
      })

    assert elem(empty, 0).assigns.all_slots == []
    assert names(empty) == []

    assert LazyHTML.query(LazyHTML.from_fragment(html(empty)), "#gantt-scroll")
           |> LazyHTML.to_tree() == []

    assert html(empty) =~ "No schedule uploaded yet."
  end

  defp event({socket, fingerprints, components, rendered}, event, params) do
    {:noreply, changed} = Index.handle_event(event, params, socket)
    render_state({changed, fingerprints, components, rendered})
  end

  defp render_state({socket, fingerprints, components, previous}) do
    rendered = Renderer.to_rendered(socket, Index)
    {diff, fingerprints, components} = Diff.render(socket, rendered, fingerprints, components)
    socket = Utils.clear_changed(socket)
    diff = Diff.render_private(socket, diff)
    socket = Utils.clear_temp(socket)
    merged = ClientDiff.merge_diff(previous, diff)
    {{socket, fingerprints, components, merged}, diff}
  end

  defp html(state), do: state |> elem(3) |> Diff.to_iodata() |> IO.iodata_to_binary()

  defp grid(state),
    do:
      state
      |> html()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#gantt-scroll")
      |> LazyHTML.to_html()

  defp names(state),
    do:
      state
      |> html()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("[data-tour-resident-name] a")
      |> LazyHTML.to_tree()
      |> Enum.map(fn {_tag, _, children} -> children |> Enum.join() |> String.trim() end)
      |> Enum.sort()

  defp first_token(state),
    do:
      state
      |> html()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("button[data-action='open_rotation_details']")
      |> LazyHTML.attribute("phx-value-cell-id")
      |> hd()

  defp rotations(nil), do: []
  defp rotations(%{rotations: rotations}), do: rotations
  defp rotations(rotation), do: [rotation]

  defp assert_no_rows(diff, path),
    do: assert(get_in(diff, path) == nil, "event resent the schedule row comprehension")

  defp dynamic_paths(value, needle, path \\ [])

  defp dynamic_paths(value, needle, path) when is_map(value) do
    own =
      case Map.get(value, :s) do
        statics when is_list(statics) ->
          static_paths(statics, needle, path)

        _ ->
          []
      end

    own ++
      Enum.flat_map(value, fn {key, item} ->
        if key == :s, do: [], else: dynamic_paths(item, needle, path ++ [key])
      end)
  end

  defp dynamic_paths(_, _, _), do: []

  defp static_paths(statics, needle, path) do
    statics
    |> Enum.with_index()
    |> Enum.flat_map(fn {part, index} ->
      if is_binary(part) and String.contains?(part, needle), do: [path ++ [index]], else: []
    end)
  end
end
