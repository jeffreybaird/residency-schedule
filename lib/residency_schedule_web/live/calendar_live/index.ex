defmodule ResidencyScheduleWeb.CalendarLive.Index do
  use ResidencyScheduleWeb, :live_view

  alias ResidencySchedule.Schedules
  alias ResidencySchedule.Rotations
  alias ResidencySchedule.Residents
  alias ResidencySchedule.ShiftOverrides

  @impl true
  def mount(_params, session, socket) do
    current_user = load_current_user(session)

    socket =
      assign(socket,
        any_schedules?: Schedules.list_schedules() != [],
        view_mode: :week,
        focus_date: Date.utc_today(),
        resident_filter: default_resident_filter(current_user),
        rotation_filter: [],
        filter_panel: nil,
        selected_date: nil,
        current_user: current_user,
        show_tour: show_tour?(current_user)
      )

    {:ok, socket}
  end

  # Pre-selects the user's assigned (home) resident so the calendar opens on
  # their own schedule. Filters by the person (resident_id), so navigating into
  # the next academic year keeps showing them. Users without an assigned
  # resident see everyone.
  defp default_resident_filter(%{home_resident: %{resident_id: resident_id}})
       when is_integer(resident_id),
       do: [resident_id]

  defp default_resident_filter(_current_user), do: []

  # New users see the guided tour automatically until they complete it.
  defp show_tour?(%{tour_completed: false}), do: true
  defp show_tour?(_current_user), do: false

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket
     |> maybe_put_view(params["view"])
     |> maybe_put_date(params["date"])
     |> assign_view_data()}
  end

  defp maybe_put_view(socket, view) when view in ["month", "week", "day"] do
    assign(socket, view_mode: parse_view(view))
  end

  defp maybe_put_view(socket, _view), do: socket

  defp maybe_put_date(socket, nil), do: socket

  defp maybe_put_date(socket, date) do
    case Date.from_iso8601(date) do
      {:ok, focus_date} -> assign(socket, focus_date: focus_date)
      {:error, _} -> socket
    end
  end

  @impl true
  def handle_event("set_view", %{"view" => view}, socket) do
    {:noreply,
     socket
     |> assign(view_mode: parse_view(view), selected_date: nil)
     |> assign_view_data()
     |> persist_prefs()}
  end

  @impl true
  def handle_event("prev", _params, socket) do
    {:noreply,
     socket
     |> assign(
       focus_date: shift_focus(socket.assigns.view_mode, socket.assigns.focus_date, -1),
       selected_date: nil
     )
     |> assign_view_data()}
  end

  @impl true
  def handle_event("next", _params, socket) do
    {:noreply,
     socket
     |> assign(
       focus_date: shift_focus(socket.assigns.view_mode, socket.assigns.focus_date, 1),
       selected_date: nil
     )
     |> assign_view_data()}
  end

  @impl true
  def handle_event("today", _params, socket) do
    {:noreply,
     socket
     |> assign(focus_date: Date.utc_today(), selected_date: nil)
     |> assign_view_data()}
  end

  @impl true
  def handle_event("select_day", %{"date" => date_str}, socket) do
    {:noreply, assign(socket, selected_date: Date.from_iso8601!(date_str))}
  end

  @impl true
  def handle_event("open_day_view", %{"date" => date_str}, socket) do
    {:noreply,
     socket
     |> assign(
       view_mode: :day,
       focus_date: Date.from_iso8601!(date_str),
       selected_date: nil
     )
     |> assign_view_data()
     |> persist_prefs()}
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, selected_date: nil)}
  end

  @impl true
  def handle_event("toggle_filter_panel", %{"panel" => panel}, socket) do
    panel = parse_panel(panel)
    open = if socket.assigns.filter_panel == panel, do: nil, else: panel
    {:noreply, socket |> assign(filter_panel: open) |> persist_prefs()}
  end

  @impl true
  def handle_event("toggle_resident_filter", %{"id" => id}, socket) do
    resident_filter = toggle_in_list(socket.assigns.resident_filter, String.to_integer(id))
    {:noreply, socket |> assign(resident_filter: resident_filter) |> persist_prefs()}
  end

  @impl true
  def handle_event("toggle_rotation_filter", %{"type" => type}, socket) do
    rotation_filter = toggle_in_list(socket.assigns.rotation_filter, type)
    {:noreply, socket |> assign(rotation_filter: rotation_filter) |> persist_prefs()}
  end

  @impl true
  def handle_event("clear_resident_filter", _params, socket) do
    {:noreply, socket |> assign(resident_filter: []) |> persist_prefs()}
  end

  @impl true
  def handle_event("clear_rotation_filter", _params, socket) do
    {:noreply, socket |> assign(rotation_filter: []) |> persist_prefs()}
  end

  # Restores view mode, resident/rotation filters and the open filter panel from
  # the client's saved preferences. Pushed by the CalendarPrefs hook on mount, so
  # choices survive a refresh or navigating away and back.
  @impl true
  def handle_event("restore_prefs", params, socket) do
    {:noreply,
     socket
     |> restore_view(params["view"])
     |> restore_resident_filter(params["residents"])
     |> restore_rotation_filter(params["rotations"])
     |> restore_filter_panel(params["panel"])
     |> assign_view_data()}
  end

  @impl true
  def handle_event("tour_completed", _params, socket) do
    if socket.assigns.current_user do
      ResidencySchedule.Accounts.complete_tour(socket.assigns.current_user)
    end

    {:noreply, assign(socket, show_tour: false)}
  end

  @impl true
  def handle_event("restart_tour", _params, socket) do
    {:noreply, push_event(socket, "start-tour", %{})}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="guided-tour"
      phx-hook="GuidedTour"
      data-tour-page="calendar"
      data-auto-start={to_string(@show_tour)}
      class="max-w-4xl mx-auto py-10 px-4"
    >
      <div id="calendar-prefs" phx-hook="CalendarPrefs" class="hidden"></div>
      <div class="flex flex-wrap items-center justify-between gap-3 mb-6">
        <div class="flex items-center gap-3">
          <h1 class="text-2xl font-bold text-gray-800">Calendar</h1>
          <button
            phx-click="restart_tour"
            class="text-sm text-blue-500 hover:text-blue-700 transition-colors"
            title="Take a guided tour"
          >
            Take a tour
          </button>
        </div>
        <div id="tour-view-toggle" class="flex items-center gap-1 bg-gray-100 rounded-lg p-1">
          <%= for {mode, label} <- [{:month, "Month"}, {:week, "Week"}, {:day, "Day"}] do %>
            <button
              phx-click="set_view"
              phx-value-view={mode}
              class={view_btn_class(@view_mode, mode)}
            >
              {label}
            </button>
          <% end %>
        </div>
      </div>

      <%= if @any_schedules? do %>
        <.filter_controls
          resident_options={@resident_options}
          type_options={@type_options}
          resident_filter={@resident_filter}
          rotation_filter={@rotation_filter}
          filter_panel={@filter_panel}
        />

        <div id="tour-month-nav" class="flex items-center justify-between mb-4">
          <button
            phx-click="prev"
            class="px-3 py-1.5 rounded-md bg-gray-100 hover:bg-gray-200 text-sm font-medium transition-colors"
          >
            ← Prev
          </button>
          <div class="flex items-center gap-3">
            <h2 class="text-lg font-semibold text-gray-700">
              {period_label(@view_mode, @focus_date)}
            </h2>
            <button
              phx-click="today"
              class="px-2 py-1 rounded-md text-xs font-medium text-blue-600 hover:bg-blue-50 transition-colors"
            >
              Today
            </button>
          </div>
          <button
            phx-click="next"
            class="px-3 py-1.5 rounded-md bg-gray-100 hover:bg-gray-200 text-sm font-medium transition-colors"
          >
            Next →
          </button>
        </div>

        <div id="calendar-swipe" phx-hook="CalendarSwipe" style="touch-action: pan-y">
          <%= case @view_mode do %>
            <% :month -> %>
            <div
              id="tour-calendar-grid"
              class="grid grid-cols-7 gap-px bg-gray-200 border border-gray-200 rounded-xl overflow-hidden shadow-sm"
            >
              <.weekday_headers />
              <%= for day <- calendar_days(@focus_date) do %>
                <% rotations = visible_rotations(assigns, day) %>
                <div
                  phx-click="select_day"
                  phx-value-date={Date.to_iso8601(day)}
                  class={[
                    "relative bg-white p-1 sm:p-2 h-14 sm:h-20 cursor-pointer border-0 transition-colors hover:bg-blue-50",
                    if(day.month == @focus_date.month, do: "", else: "opacity-40")
                  ]}
                >
                  <span class={[
                    "text-sm font-medium",
                    if(day == Date.utc_today(), do: "text-blue-600 font-bold", else: "text-gray-700")
                  ]}>
                    {day.day}
                  </span>
                  <div class="flex flex-wrap gap-0.5 mt-1">
                    <%= for {type, _rots} <- Enum.take(group_by_type(rotations), 6) do %>
                      <span
                        class={"w-2 h-2 rounded-full #{dot_color(type)}"}
                        title={Rotations.rotation_type_label(type)}
                      >
                      </span>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>

          <% :week -> %>
            <div
              id="tour-calendar-grid"
              class="grid grid-cols-7 gap-px bg-gray-200 border border-gray-200 rounded-xl overflow-hidden shadow-sm"
            >
              <.weekday_headers />
              <%= for day <- week_days(@focus_date) do %>
                <% groups = group_by_type(visible_rotations(assigns, day)) %>
                <div
                  phx-click="select_day"
                  phx-value-date={Date.to_iso8601(day)}
                  class="bg-white p-2 min-h-[8rem] cursor-pointer transition-colors hover:bg-blue-50"
                >
                  <span class={[
                    "text-sm font-medium",
                    if(day == Date.utc_today(), do: "text-blue-600 font-bold", else: "text-gray-700")
                  ]}>
                    {day.day}
                  </span>
                  <div class="mt-1 space-y-1">
                    <%= for {type, rots} <- groups do %>
                      <div class={"flex items-center justify-between gap-1 rounded px-1 py-0.5 text-[10px] leading-tight #{Rotations.rotation_type_color(type)}"}>
                        <span class="truncate">{Rotations.rotation_type_label(type)}</span>
                        <span class="font-mono opacity-80">{length(rots)}</span>
                      </div>
                    <% end %>
                  </div>
                </div>
              <% end %>
            </div>

          <% :day -> %>
            <div id="tour-calendar-grid" class="bg-white border border-gray-200 rounded-xl shadow-sm p-6">
              <h3 class="text-lg font-semibold text-gray-800 mb-4">
                {Calendar.strftime(@focus_date, "%A, %B %-d, %Y")}
              </h3>
              <.detail_groups groups={day_detail_for(assigns, @focus_date)} />
            </div>
          <% end %>
        </div>

        <%!-- Day detail modal (month and week views) --%>
        <%= if @selected_date && @view_mode in [:month, :week] do %>
          <div class="fixed inset-0 z-50 flex items-center justify-center">
            <div phx-click="close_modal" class="absolute inset-0 bg-black/40"></div>
            <div class="relative bg-white rounded-xl shadow-2xl max-w-md w-full mx-4 z-10 max-h-[80vh] flex flex-col">
              <div class="flex items-start justify-between p-6 pb-4 shrink-0">
                <h3 class="text-lg font-semibold text-gray-800">
                  {Calendar.strftime(@selected_date, "%A, %B %-d, %Y")}
                </h3>
                <div class="flex items-center gap-3 ml-4">
                  <button
                    phx-click="open_day_view"
                    phx-value-date={Date.to_iso8601(@selected_date)}
                    class="text-xs font-medium text-blue-600 hover:underline whitespace-nowrap"
                  >
                    Day view
                  </button>
                  <button
                    phx-click="close_modal"
                    class="text-gray-400 hover:text-gray-600 text-xl leading-none"
                  >
                    ✕
                  </button>
                </div>
              </div>

              <div class="overflow-y-auto px-6 pb-6">
                <.detail_groups groups={day_detail_for(assigns, @selected_date)} />
              </div>
            </div>
          </div>
        <% end %>
      <% else %>
        <div class="text-center py-20">
          <p class="text-gray-500">No schedule uploaded yet.</p>
        </div>
      <% end %>
    </div>
    """
  end

  # The Sun–Sat header row shared by the month and week grids.
  defp weekday_headers(assigns) do
    ~H"""
    <%= for {short, long} <- [{"Su","Sun"},{"Mo","Mon"},{"Tu","Tue"},{"We","Wed"},{"Th","Thu"},{"Fr","Fri"},{"Sa","Sat"}] do %>
      <div class="bg-gray-50 px-1 py-2 text-center text-xs font-semibold text-gray-500 uppercase tracking-wide">
        <span class="sm:hidden">{short}</span>
        <span class="hidden sm:inline">{long}</span>
      </div>
    <% end %>
    """
  end

  # Renders the resident and rotation filter dropdowns plus their open panel.
  defp filter_controls(assigns) do
    ~H"""
    <div id="tour-calendar-filters" class="mb-4">
      <div class="flex flex-wrap items-center gap-2">
        <button
          phx-click="toggle_filter_panel"
          phx-value-panel="residents"
          class={filter_toggle_class(@filter_panel == :residents, @resident_filter != [])}
        >
          Residents{filter_count_suffix(@resident_filter)}
        </button>
        <button
          phx-click="toggle_filter_panel"
          phx-value-panel="rotations"
          class={filter_toggle_class(@filter_panel == :rotations, @rotation_filter != [])}
        >
          Rotations{filter_count_suffix(@rotation_filter)}
        </button>
      </div>

      <%= if @filter_panel == :residents do %>
        <div class="mt-2 rounded-lg border border-gray-200 bg-white shadow-sm p-3">
          <div class="flex items-center justify-between mb-2">
            <span class="text-xs font-semibold text-gray-500 uppercase tracking-wide">Residents</span>
            <button phx-click="clear_resident_filter" class="text-xs text-blue-600 hover:underline">
              All
            </button>
          </div>
          <%= if @resident_options == [] do %>
            <p class="text-sm text-gray-400">No residents yet.</p>
          <% else %>
            <div class="flex flex-wrap gap-1.5 max-h-48 overflow-y-auto">
              <%= for resident <- @resident_options do %>
                <button
                  phx-click="toggle_resident_filter"
                  phx-value-id={resident.id}
                  class={filter_chip_class(resident.id in @resident_filter)}
                >
                  <span class="font-mono text-[10px] opacity-70">{resident.position_code}</span>
                  {resident.name}
                </button>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>

      <%= if @filter_panel == :rotations do %>
        <div class="mt-2 rounded-lg border border-gray-200 bg-white shadow-sm p-3">
          <div class="flex items-center justify-between mb-2">
            <span class="text-xs font-semibold text-gray-500 uppercase tracking-wide">Rotations</span>
            <button phx-click="clear_rotation_filter" class="text-xs text-blue-600 hover:underline">
              All
            </button>
          </div>
          <%= if @type_options == [] do %>
            <p class="text-sm text-gray-400">No rotations in view.</p>
          <% else %>
            <div class="flex flex-wrap gap-1.5 max-h-48 overflow-y-auto">
              <%= for type <- @type_options do %>
                <button
                  phx-click="toggle_rotation_filter"
                  phx-value-type={type}
                  class={[
                    "inline-flex items-center rounded-full px-2.5 py-1 text-xs font-medium transition-colors",
                    if(type in @rotation_filter,
                      do: Rotations.rotation_type_color(type),
                      else: "bg-gray-100 text-gray-700 hover:bg-gray-200"
                    )
                  ]}
                >
                  {Rotations.rotation_type_label(type)}
                </button>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # Renders rotation assignments for a day, grouped by rotation type.
  defp detail_groups(assigns) do
    ~H"""
    <%= if @groups == [] do %>
      <p class="text-sm text-gray-400">No rotations recorded for this day.</p>
    <% else %>
      <div class="space-y-4">
        <%= for {type, entries} <- @groups do %>
          <div>
            <div class="flex items-center gap-2 mb-2">
              <span class={"inline-block rounded px-2 py-0.5 text-xs font-medium #{Rotations.rotation_type_color(type)}"}>
                {Rotations.rotation_type_label(type)}
              </span>
              <span class="text-xs text-gray-400">
                {length(entries)} resident{if length(entries) != 1, do: "s"}
              </span>
            </div>
            <ul class="space-y-1 pl-1">
              <%= for entry <- entries do %>
                <li class="flex items-center gap-2 text-sm">
                  <span class="text-xs text-gray-400 font-mono w-10">
                    {entry.resident.position_code}
                  </span>
                  <.link
                    navigate={"/residents/#{entry.resident.id}"}
                    class={[
                      "hover:text-blue-600 hover:underline",
                      if(entry.overridden,
                        do: "line-through text-gray-400",
                        else: "text-gray-700"
                      )
                    ]}
                  >
                    {entry.resident.name}
                  </.link>
                  <%= if entry.overridden do %>
                    <span class="text-xs text-gray-400 italic">
                      → {entry.covered_by.name}
                    </span>
                  <% end %>
                  <%= if entry.is_coverage do %>
                    <span class="text-xs text-blue-500 italic">(covering)</span>
                  <% end %>
                </li>
              <% end %>
            </ul>
          </div>
        <% end %>
      </div>
    <% end %>
    """
  end

  # Fetches rotations and overrides for the visible range and indexes them by date,
  # along with the resident and rotation-type options available for filtering.
  defp assign_view_data(socket) do
    focus_date = socket.assigns.focus_date
    {range_start, range_end} = visible_range(socket.assigns.view_mode, focus_date)
    rotations = Rotations.list_rotations_in_range_all_schedules(range_start, range_end)
    overrides = ShiftOverrides.list_overrides_in_range(range_start, range_end)
    academic_year = ResidencyScheduleWeb.ScheduleLive.Index.current_academic_year(focus_date)

    assign(socket,
      rotation_index: index_by_date(rotations, & &1.start_date, & &1.end_date),
      override_index: index_by_date(overrides, & &1.override_start_date, & &1.override_end_date),
      resident_options: Residents.list_resident_filter_options_for_year(academic_year),
      type_options: type_options(rotations)
    )
  end

  # Expands each item across its inclusive date range, grouping items by date.
  defp index_by_date(items, start_fun, end_fun) do
    items
    |> Enum.flat_map(fn item ->
      Date.range(start_fun.(item), end_fun.(item)) |> Enum.map(&{&1, item})
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  # Distinct rotation types appearing in the visible rotations, ordered by label.
  defp type_options(rotations) do
    rotations
    |> Enum.map(& &1.rotation_type)
    |> Enum.uniq()
    |> Enum.sort_by(&Rotations.rotation_type_label/1)
  end

  # Rotations active on a day, with the resident and rotation filters applied.
  defp visible_rotations(assigns, day) do
    Map.get(assigns.rotation_index, day, [])
    |> Rotations.filter_rotations_by_residents(assigns.resident_filter)
    |> Rotations.filter_rotations_by_types(assigns.rotation_filter)
  end

  # Effective assignments for a day, filtered and grouped by rotation type for display.
  defp day_detail_for(assigns, date) do
    visible_rotations(assigns, date)
    |> Rotations.effective_day_assignments(Map.get(assigns.override_index, date, []))
    |> Enum.group_by(& &1.rotation_type)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp group_by_type(rotations) do
    rotations
    |> Enum.group_by(& &1.rotation_type)
    |> Enum.sort_by(&elem(&1, 0))
  end

  # The inclusive date range covered by a view mode anchored on focus_date.
  defp visible_range(:month, focus_date) do
    first = Date.beginning_of_month(focus_date)
    last = Date.end_of_month(focus_date)
    start_dow = Date.day_of_week(first, :sunday)
    grid_start = Date.add(first, -(start_dow - 1))
    end_dow = Date.day_of_week(last, :sunday)
    grid_end = Date.add(last, 7 - end_dow)
    {grid_start, grid_end}
  end

  defp visible_range(:week, focus_date), do: week_bounds(focus_date)
  defp visible_range(:day, focus_date), do: {focus_date, focus_date}

  defp calendar_days(focus_date) do
    {grid_start, grid_end} = visible_range(:month, focus_date)
    Date.range(grid_start, grid_end) |> Enum.to_list()
  end

  defp week_days(focus_date) do
    {week_start, week_end} = week_bounds(focus_date)
    Date.range(week_start, week_end) |> Enum.to_list()
  end

  defp week_bounds(date) do
    dow = Date.day_of_week(date, :sunday)
    week_start = Date.add(date, -(dow - 1))
    {week_start, Date.add(week_start, 6)}
  end

  defp shift_focus(:month, date, direction), do: Date.shift(date, month: direction)
  defp shift_focus(:week, date, direction), do: Date.shift(date, day: 7 * direction)
  defp shift_focus(:day, date, direction), do: Date.shift(date, day: direction)

  defp period_label(:month, date), do: Calendar.strftime(date, "%B %Y")

  defp period_label(:week, date) do
    {week_start, week_end} = week_bounds(date)
    "#{Calendar.strftime(week_start, "%b %-d")} – #{Calendar.strftime(week_end, "%b %-d, %Y")}"
  end

  defp period_label(:day, date), do: Calendar.strftime(date, "%A, %B %-d, %Y")

  # Pushes the current view, filters and open panel to the client so the
  # CalendarPrefs hook can store them in localStorage.
  defp persist_prefs(socket) do
    push_event(socket, "save_calendar_prefs", %{
      view: Atom.to_string(socket.assigns.view_mode),
      residents: socket.assigns.resident_filter,
      rotations: socket.assigns.rotation_filter,
      panel: panel_to_string(socket.assigns.filter_panel)
    })
  end

  defp panel_to_string(nil), do: nil
  defp panel_to_string(panel), do: Atom.to_string(panel)

  defp restore_view(socket, view) when view in ["month", "week", "day"],
    do: assign(socket, view_mode: parse_view(view))

  defp restore_view(socket, _view), do: socket

  defp restore_resident_filter(socket, ids) when is_list(ids),
    do: assign(socket, resident_filter: Enum.flat_map(ids, &coerce_resident_id/1))

  defp restore_resident_filter(socket, _ids), do: socket

  defp coerce_resident_id(id) when is_integer(id), do: [id]

  defp coerce_resident_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {int, _} -> [int]
      :error -> []
    end
  end

  defp coerce_resident_id(_id), do: []

  defp restore_rotation_filter(socket, types) when is_list(types),
    do: assign(socket, rotation_filter: Enum.filter(types, &is_binary/1))

  defp restore_rotation_filter(socket, _types), do: socket

  defp restore_filter_panel(socket, "residents"), do: assign(socket, filter_panel: :residents)
  defp restore_filter_panel(socket, "rotations"), do: assign(socket, filter_panel: :rotations)
  defp restore_filter_panel(socket, _panel), do: assign(socket, filter_panel: nil)

  defp parse_view("week"), do: :week
  defp parse_view("day"), do: :day
  defp parse_view(_), do: :month

  defp parse_panel("rotations"), do: :rotations
  defp parse_panel(_), do: :residents

  defp toggle_in_list(list, item) do
    if item in list, do: List.delete(list, item), else: [item | list]
  end

  defp view_btn_class(current, mode) do
    base = "px-3 py-1 rounded-md text-sm font-medium transition-colors"

    if current == mode,
      do: "#{base} bg-white text-blue-600 shadow-sm",
      else: "#{base} text-gray-600 hover:text-gray-800"
  end

  defp filter_toggle_class(open?, active?) do
    base = "px-3 py-1.5 rounded-md text-sm font-medium transition-colors border"

    cond do
      open? -> "#{base} bg-blue-600 text-white border-blue-600"
      active? -> "#{base} bg-blue-50 text-blue-700 border-blue-200"
      true -> "#{base} bg-white text-gray-700 border-gray-200 hover:bg-gray-50"
    end
  end

  defp filter_chip_class(selected?) do
    base = "inline-flex items-center gap-1 rounded-full px-2.5 py-1 text-xs font-medium transition-colors"

    if selected?,
      do: "#{base} bg-blue-600 text-white",
      else: "#{base} bg-gray-100 text-gray-700 hover:bg-gray-200"
  end

  defp filter_count_suffix([]), do: ""
  defp filter_count_suffix(list), do: " (#{length(list)})"

  defp dot_color(rotation_type) do
    Rotations.rotation_type_color(rotation_type)
    |> String.split()
    |> List.first()
  end

  defp load_current_user(session) do
    case session["user_id"] do
      nil -> nil
      user_id -> ResidencySchedule.Accounts.get_user(user_id)
    end
  end
end
