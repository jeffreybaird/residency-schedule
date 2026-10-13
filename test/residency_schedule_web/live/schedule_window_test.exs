defmodule ResidencyScheduleWeb.ScheduleWindowTest do
  use ResidencyScheduleWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  alias Phoenix.LiveView.{Socket, Utils}
  alias ResidencySchedule.ScheduleWindow
  alias ResidencyScheduleWeb.{Endpoint, ScheduleLive.Index}

  setup :authenticate_session

  setup do
    previous = Application.get_env(:residency_schedule, :current_date)
    Application.put_env(:residency_schedule, :current_date, ~D[2023-12-01])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:residency_schedule, :current_date, previous),
        else: Application.delete_env(:residency_schedule, :current_date)
    end)

    seed_schedule()
    user = create_admin("window-password")

    {:ok, socket} =
      Index.mount(%{}, %{}, %Socket{
        view: Index,
        endpoint: Endpoint,
        transport_pid: self(),
        assigns: %{__changed__: %{}, current_user: user}
      })

    %{socket: socket}
  end

  test "initial actual LiveView materializes a useful bounded date window with complete scroll metadata",
       %{conn: conn, socket: socket} do
    {:ok, view, html} = live(conn, "/schedule")
    full = socket.assigns.all_slots
    assert length(full) > 40
    document = LazyHTML.from_fragment(html)

    assert length(
             LazyHTML.query(document, "#gantt-scroll th[data-slot-aca-year]")
             |> LazyHTML.to_tree()
           ) == 40

    [metadata] =
      LazyHTML.query(document, "#gantt-scroll") |> LazyHTML.attribute("data-slot-metadata")

    assert length(Jason.decode!(metadata)) == length(full)

    assert LazyHTML.query(document, "#gantt-scroll") |> LazyHTML.attribute("data-slot-width") == [
             "80"
           ]

    assert LazyHTML.query(document, "#gantt-scroll") |> LazyHTML.attribute("data-name-width") == [
             "148"
           ]

    assert has_element?(view, "#gantt-scroll th[data-today-slot]")
    assert has_element?(view, "#gantt-scroll[tabindex='0']")
    assert has_element?(view, "#gantt-scroll th[data-window-spacer='left'][aria-hidden='true']")
    assert has_element?(view, "#gantt-scroll th[data-window-spacer='right'][aria-hidden='true']")

    assert socket.assigns.schedule_window.start ==
             ScheduleWindow.initial_start(full, ~D[2023-12-01])
  end

  test "first visible slot independently selects its academic year across schedules", %{
    socket: socket
  } do
    seed_schedule(2026)
    {:ok, socket} = Index.mount(%{}, %{}, socket)

    index =
      Enum.find_index(socket.assigns.all_slots, fn {_, _, date, _, _} ->
        date.year == 2026 and date.month >= 7
      end)

    assert is_integer(index)
    changed = event(socket, "update_window", %{"start" => index, "count" => 20, "first" => index})
    assert changed.assigns.viewed_aca_year == 2026
    previous = event(changed, "update_window", %{"start" => 0, "count" => 20, "first" => 0})
    assert previous.assigns.viewed_aca_year == 2023
    outside = event(previous, "update_window", %{"start" => 0, "count" => 20, "first" => index})
    assert outside.assigns.viewed_aca_year == 2023
  end

  test "window events preserve the full cached grid and clip only rendered cells", %{
    socket: socket
  } do
    full_slots = socket.assigns.all_slots
    full_rows = socket.assigns.unified_residents
    full_groups = socket.assigns.visible_resident_groups
    changed = event(socket, "update_window", %{"start" => "5", "count" => "20", "first" => "13"})
    assert changed.assigns.schedule_window == ScheduleWindow.build(full_slots, full_groups, 5, 20)
    assert changed.assigns.all_slots == full_slots
    assert changed.assigns.unified_residents == full_rows
    assert changed.assigns.visible_resident_groups == full_groups

    assert changed.assigns.schedule_window.left_px + changed.assigns.schedule_window.count * 80 +
             changed.assigns.schedule_window.right_px == length(full_slots) * 80

    for {_year, residents} <- changed.assigns.schedule_window.groups, row <- residents do
      assert Enum.sum(Enum.map(row.cells, &elem(&1, 0))) == 20
    end
  end

  test "invalid ranges never crash or enlarge the materialized window", %{socket: socket} do
    for params <- [
          %{},
          %{"start" => "bad", "count" => "20", "first" => "0"},
          %{"start" => [], "count" => %{}, "first" => nil},
          %{"start" => "-999", "count" => "999999", "first" => "999999"}
        ] do
      updated = event(socket, "update_window", params)
      window = updated.assigns.schedule_window
      assert window.start >= 0
      assert window.count <= 128
      assert window.finish <= length(socket.assigns.all_slots)

      assert updated.assigns.viewed_aca_year in Enum.map(socket.assigns.all_slots, fn {_, _, date,
                                                                                       _, _} ->
               if date.month >= 7, do: date.year, else: date.year - 1
             end)
    end
  end

  test "clipped pills resolve full details and closing restores an evicted opener window", %{
    socket: socket
  } do
    socket = event(socket, "update_window", %{"start" => 5, "count" => 20, "first" => 13})
    origin = socket.assigns.schedule_window

    token =
      origin.groups
      |> Enum.flat_map(&elem(&1, 1))
      |> Enum.flat_map(& &1.cells)
      |> Enum.flat_map(fn {_, cell} -> rotations(cell) end)
      |> hd()
      |> Map.fetch!(:cell_id)

    opened = event(socket, "open_rotation_details", %{"cell-id" => token})
    assert opened.assigns.rotation_modal.cell_id == token

    original =
      socket.assigns.unified_residents
      |> Enum.flat_map(& &1.cells)
      |> Enum.flat_map(fn {_, cell} -> rotations(cell) end)
      |> Enum.find(&(&1.cell_id == token))

    assert opened.assigns.rotation_modal.start_date == original.start_date
    assert opened.assigns.rotation_modal.end_date == original.end_date
    detail = opened.assigns.rotation_modal

    last = length(socket.assigns.all_slots) - 8
    moved = event(opened, "update_window", %{"start" => last, "count" => 8, "first" => last})

    assert moved.assigns.rotation_modal == detail
    assert moved.assigns.schedule_window.start != origin.start
    closed = event(moved, "close_rotation_details", %{})
    assert closed.assigns.rotation_modal == nil
    assert closed.assigns.schedule_window.start == origin.start
    assert closed.assigns.schedule_window.count == origin.count

    assert ["restore-schedule-focus", %{cell_id: token, index: 13}] in Utils.get_push_events(
             closed
           )

    assert Enum.any?(
             closed.assigns.schedule_window.groups
             |> Enum.flat_map(&elem(&1, 1))
             |> Enum.flat_map(& &1.cells)
             |> Enum.flat_map(fn {_, cell} -> rotations(cell) end),
             &(&1.cell_id == token)
           )

    assert event(closed, "close_rotation_details", %{}).assigns.schedule_window ==
             closed.assigns.schedule_window
  end

  test "filters, programmatic jumps, tour and deletion preserve window validity", %{
    socket: socket
  } do
    filtered = event(socket, "filter_year", %{"year" => "2"})

    assert filtered.assigns.schedule_window.groups ==
             ScheduleWindow.build(
               filtered.assigns.all_slots,
               filtered.assigns.visible_resident_groups,
               filtered.assigns.schedule_window.start,
               filtered.assigns.schedule_window.count
             ).groups

    [schedule | _] = socket.assigns.schedules
    jumped = event(filtered, "scroll_to_schedule", %{"id" => to_string(schedule.id)})
    assert jumped.assigns.schedule_window.start == 0

    assert event(jumped, "restart_tour", %{}).assigns.schedule_window ==
             jumped.assigns.schedule_window

    deleted =
      event(jumped, "delete_schedule", %{
        "schedule_id" => to_string(schedule.id),
        "password" => "window-password"
      })

    assert deleted.assigns.all_slots == []
    assert deleted.assigns.schedule_window.total == 0
    assert deleted.assigns.schedule_window.groups == []
  end

  test "closing a modal after crossing academic years restores its filtered cohort and original pill",
       %{socket: socket} do
    seed_schedule(2026)
    {:ok, socket} = Index.mount(%{}, %{}, socket)
    origin = event(socket, "filter_year", %{"year" => "2"})
    assert origin.assigns.viewed_aca_year == 2023

    token =
      origin.assigns.schedule_window.groups
      |> Enum.flat_map(&elem(&1, 1))
      |> Enum.flat_map(& &1.cells)
      |> Enum.flat_map(fn {_, cell} -> rotations(cell) end)
      |> hd()
      |> Map.fetch!(:cell_id)

    opened = event(origin, "open_rotation_details", %{"cell-id" => token})
    assert opened.assigns.rotation_modal.cell_id == token

    later =
      Enum.find_index(socket.assigns.all_slots, fn {_, _, date, _, _} ->
        date.year == 2026 and date.month >= 7
      end)

    moved = event(opened, "update_window", %{"start" => later, "count" => 20, "first" => later})
    assert moved.assigns.viewed_aca_year == 2026
    assert moved.assigns.visible_resident_groups != origin.assigns.visible_resident_groups
    closed = event(moved, "close_rotation_details", %{})
    assert closed.assigns.viewed_aca_year == 2023
    assert closed.assigns.filter_year == 2
    assert closed.assigns.visible_resident_groups == origin.assigns.visible_resident_groups
    assert closed.assigns.schedule_window == origin.assigns.schedule_window

    assert Enum.any?(
             closed.assigns.schedule_window.groups
             |> Enum.flat_map(&elem(&1, 1))
             |> Enum.flat_map(& &1.cells)
             |> Enum.flat_map(fn {_, cell} -> rotations(cell) end),
             &(&1.cell_id == token)
           )
  end

  defp event(socket, name, params) do
    case Index.handle_event(name, params, socket) do
      {:noreply, updated} -> updated
      {:reply, _reply, updated} -> updated
    end
  end

  defp rotations(nil), do: []
  defp rotations(%{rotations: rotations}), do: rotations
  defp rotations(rotation), do: [rotation]
end
