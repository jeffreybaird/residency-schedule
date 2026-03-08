defmodule ResidencyScheduleWeb.ScheduleLive.Index do
  use ResidencyScheduleWeb, :live_view

  alias ResidencySchedule.Schedules
  alias ResidencySchedule.Residents
  alias ResidencySchedule.Rotations

  # Fixed pixel widths for sticky label columns — must match left-[Xpx] values below.
  @id_col_px 72
  @name_col_px 128

  @impl true
  def mount(_params, _session, socket) do
    schedules = Schedules.list_schedules()
    schedule = List.first(schedules)

    socket =
      if schedule do
        load_schedule_data(socket, schedule, schedules)
      else
        assign(socket,
          schedules: [],
          schedule: nil,
          residents_by_year: %{},
          slots: [],
          filter_year: nil
        )
      end

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"schedule_id" => id}, _uri, socket) do
    schedule = Schedules.get_schedule!(String.to_integer(id))
    {:noreply, load_schedule_data(socket, schedule, socket.assigns.schedules)}
  end

  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("select_schedule", %{"id" => id}, socket) do
    schedule = Schedules.get_schedule!(String.to_integer(id))
    {:noreply, load_schedule_data(socket, schedule, socket.assigns.schedules)}
  end

  @impl true
  def handle_event("filter_year", %{"year" => year}, socket) do
    filter_year = if year == "all", do: nil, else: String.to_integer(year)
    {:noreply, assign(socket, filter_year: filter_year)}
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :id_col_px, @id_col_px)
    assigns = assign(assigns, :name_col_px, @name_col_px)

    ~H"""
    <div class="min-h-screen bg-gray-50">
      <%= if length(@schedules) > 1 do %>
        <div class="bg-white border-b border-gray-200 px-6 py-2 flex items-center gap-2">
          <span class="text-sm text-gray-500">Year:</span>
          <%= for s <- @schedules do %>
            <button
              phx-click="select_schedule"
              phx-value-id={s.id}
              class={[
                "px-3 py-1 rounded-full text-sm font-medium transition-colors",
                if(@schedule && @schedule.id == s.id,
                  do: "bg-blue-600 text-white",
                  else: "bg-gray-100 text-gray-700 hover:bg-gray-200"
                )
              ]}
            >
              <%= s.label %>
            </button>
          <% end %>
        </div>
      <% end %>

      <%= if @schedule do %>
        <div class="px-6 py-4 flex items-center gap-6 border-b border-gray-200 bg-white">
          <div class="flex items-center gap-2">
            <span class="text-sm text-gray-500 font-medium">Year:</span>
            <button
              phx-click="filter_year"
              phx-value-year="all"
              class={filter_tab_class(@filter_year, nil)}
            >
              All
            </button>
            <%= for y <- 1..4 do %>
              <button
                phx-click="filter_year"
                phx-value-year={y}
                class={filter_tab_class(@filter_year, y)}
              >
                R<%= y %>
              </button>
            <% end %>
          </div>

          <span
            id="gantt-year-indicator"
            class="ml-auto text-sm font-semibold text-gray-500 tabular-nums"
          >
          </span>
        </div>

        <div id="gantt-scroll" phx-hook="YearTracker" class="overflow-x-auto">
          <table class="border-collapse text-xs">
            <thead>
              <tr class="bg-gray-100 sticky top-0 z-30">
                <%!-- z-40 so header stickies beat both body stickies and data cells --%>
                <th
                  class="sticky left-0 z-40 bg-gray-100 px-2 py-2 text-left font-semibold text-gray-600 border-b border-r border-gray-300 whitespace-nowrap overflow-hidden"
                  style={"width: #{@id_col_px}px; min-width: #{@id_col_px}px; max-width: #{@id_col_px}px"}
                >
                  ID
                </th>
                <th
                  class="sticky z-40 bg-gray-100 px-2 py-2 text-left font-semibold text-gray-600 border-b border-r border-gray-300 whitespace-nowrap overflow-hidden"
                  style={"left: #{@id_col_px}px; width: #{@name_col_px}px; min-width: #{@name_col_px}px; max-width: #{@name_col_px}px"}
                >
                  Name
                </th>
                <%= for {_idx, start_date, end_date} <- @slots do %>
                  <th
                    class="px-1 py-2 text-center font-medium text-gray-500 border-b border-gray-200 whitespace-nowrap"
                    style="min-width: 52px"
                    data-slot-year={start_date.year}
                  >
                    <%= slot_header_label(start_date, end_date) %>
                  </th>
                <% end %>
              </tr>
            </thead>
            <tbody>
              <%= for {year, residents} <- visible_residents(@residents_by_year, @filter_year) do %>
                <tr class="bg-gray-50">
                  <td
                    colspan={2 + length(@slots)}
                    class="px-3 py-1 text-xs font-semibold text-gray-500 uppercase tracking-wide border-b border-gray-200"
                  >
                    R<%= year %> Residents
                  </td>
                </tr>
                <%= for resident <- residents do %>
                  <tr class="hover:bg-gray-50 transition-colors border-b border-gray-100">
                    <%!-- z-20 so body stickies beat scrolling data cells --%>
                    <td
                      class="sticky left-0 z-20 bg-white px-2 py-1 font-mono text-gray-500 border-r border-gray-200 overflow-hidden"
                      style={"width: #{@id_col_px}px; min-width: #{@id_col_px}px; max-width: #{@id_col_px}px"}
                    >
                      <.link navigate={"/residents/#{resident.id}"} class="hover:text-blue-600">
                        <%= resident.position_code %>
                      </.link>
                    </td>
                    <td
                      class="sticky z-20 bg-white px-2 py-1 text-gray-700 font-medium border-r border-gray-200 overflow-hidden"
                      style={"left: #{@id_col_px}px; width: #{@name_col_px}px; min-width: #{@name_col_px}px; max-width: #{@name_col_px}px"}
                    >
                      <.link navigate={"/residents/#{resident.id}"} class="hover:text-blue-600 truncate block">
                        <%= resident.name %>
                      </.link>
                    </td>
                    <%= for {colspan, rotation} <- cell_groups(@slots, resident.rotations) do %>
                      <td
                        colspan={colspan}
                        class="px-0.5 py-0.5 text-center border-r border-gray-100"
                      >
                        <%= render_rotation_cell(rotation) %>
                      </td>
                    <% end %>
                  </tr>
                <% end %>
              <% end %>
            </tbody>
          </table>
        </div>
      <% else %>
        <div class="flex flex-col items-center justify-center py-24 text-center">
          <p class="text-gray-500 mb-4">No schedule uploaded yet.</p>
          <.link
            navigate="/upload"
            class="bg-blue-600 text-white px-4 py-2 rounded-md hover:bg-blue-700 transition-colors"
          >
            Upload a Schedule
          </.link>
        </div>
      <% end %>
    </div>
    """
  end

  # --- Private helpers ---

  defp load_schedule_data(socket, schedule, schedules) do
    residents = Residents.list_residents_for_schedule(schedule.id)
    residents_with_rotations = Enum.map(residents, &load_rotations/1)
    residents_by_year = Enum.group_by(residents_with_rotations, & &1.residency_year)
    slots = build_slots(residents_with_rotations)

    assign(socket,
      schedules: schedules,
      schedule: schedule,
      residents_by_year: residents_by_year,
      slots: slots,
      filter_year: nil
    )
  end

  defp load_rotations(resident) do
    rotations = Rotations.list_rotations_for_resident(resident.id)
    Map.put(resident, :rotations, rotations)
  end

  defp build_slots([]), do: []

  defp build_slots(residents) do
    residents
    |> Enum.flat_map(fn r -> r.rotations end)
    |> Enum.map(fn rot -> {rot.slot_index, rot.start_date, rot.end_date} end)
    |> Enum.uniq_by(&elem(&1, 0))
    |> Enum.sort_by(&elem(&1, 0))
  end

  @doc false
  def slot_header_label(start_date, end_date) do
    if start_date.month == end_date.month do
      "#{start_date.day}–#{end_date.day} #{Calendar.strftime(start_date, "%b")}"
    else
      "#{Calendar.strftime(start_date, "%-d %b")}–#{Calendar.strftime(end_date, "%-d %b")}"
    end
  end

  @doc false
  def cell_groups(slots, rotations) do
    rotation_by_slot = Enum.into(rotations, %{}, fn r -> {r.slot_index, r} end)

    slots
    |> Enum.map(fn {idx, _start, _end} -> Map.get(rotation_by_slot, idx) end)
    |> Enum.chunk_by(fn
      nil -> :blank
      r -> r.rotation_type
    end)
    |> Enum.map(fn group ->
      colspan = length(group)
      rotation = Enum.find(group, &(&1 != nil))
      {colspan, rotation}
    end)
  end

  defp render_rotation_cell(nil) do
    Phoenix.HTML.raw(~s(<span class="text-gray-200">–</span>))
  end

  defp render_rotation_cell(rotation) do
    color = Rotations.rotation_type_color(rotation.rotation_type)

    Phoenix.HTML.raw(
      ~s(<span class="inline-block rounded px-1 py-0.5 text-xs font-medium whitespace-nowrap #{color}">#{abbrev(rotation.rotation_type)}</span>)
    )
  end

  @abbrev_map %{
    "ambulatory" => "AMB",
    "away_rotation" => "AWAY",
    "elective" => "Elec",
    "float" => "FLOAT",
    "strong_gynecology" => "GYN",
    "highland_gynecology" => "HGYN",
    "highland_obstetrics" => "HHOB",
    "highland_night_float" => "HNF",
    "highland_weekend_days" => "HWD",
    "highland_weekend_nights" => "HWN",
    "night_float" => "NF",
    "strong_obstetrics" => "OB",
    "oncology" => "ONC",
    "post_call" => "P",
    "rei" => "REI",
    "strong_weekend_days" => "SWD",
    "strong_weekend_nights" => "SWN",
    "swing" => "Swing",
    "urogynecology" => "UG",
    "unknown" => "USN",
    "vacation" => "Vac"
  }

  defp abbrev(rotation_type), do: Map.get(@abbrev_map, rotation_type, rotation_type)

  defp visible_residents(residents_by_year, nil),
    do: Enum.sort_by(residents_by_year, &elem(&1, 0))

  defp visible_residents(residents_by_year, year) do
    residents_by_year
    |> Enum.filter(fn {y, _} -> y == year end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp filter_tab_class(current, value) do
    base = "px-3 py-1 rounded-full text-sm font-medium transition-colors"

    if current == value,
      do: "#{base} bg-blue-600 text-white",
      else: "#{base} bg-gray-100 text-gray-700 hover:bg-gray-200"
  end
end
