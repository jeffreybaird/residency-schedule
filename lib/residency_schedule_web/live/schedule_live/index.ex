defmodule ResidencyScheduleWeb.ScheduleLive.Index do
  use ResidencyScheduleWeb, :live_view

  alias ResidencySchedule.Schedules
  alias ResidencySchedule.Residents
  alias ResidencySchedule.Rotations

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
          filter_year: nil,
          filter_type: nil
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
  def handle_event("filter_type", %{"type" => type}, socket) do
    filter_type = if type == "", do: nil, else: type
    {:noreply, assign(socket, filter_type: filter_type)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-50">
      <header class="bg-white border-b border-gray-200 px-6 py-4 flex items-center justify-between">
        <h1 class="text-xl font-semibold text-gray-800">Residency Schedule</h1>
        <div class="flex items-center gap-4">
          <%= if length(@schedules) > 1 do %>
            <div class="flex items-center gap-2">
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
          <.link
            navigate="/upload"
            class="text-sm bg-blue-600 text-white px-3 py-1.5 rounded-md hover:bg-blue-700 transition-colors"
          >
            Upload Schedule
          </.link>
        </div>
      </header>

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

          <div class="flex items-center gap-2">
            <span class="text-sm text-gray-500 font-medium">Type:</span>
            <select
              phx-change="filter_type"
              name="type"
              class="text-sm border border-gray-300 rounded-md px-2 py-1 focus:outline-none focus:ring-2 focus:ring-blue-500"
            >
              <option value="">All rotations</option>
              <%= for type <- Rotations.all_rotation_types() do %>
                <option value={type} selected={@filter_type == type}>
                  <%= Rotations.rotation_type_label(type) %>
                </option>
              <% end %>
            </select>
          </div>
        </div>

        <div class="overflow-x-auto">
          <table class="min-w-full border-collapse text-xs">
            <thead>
              <tr class="bg-gray-100 sticky top-0 z-10">
                <th class="sticky left-0 bg-gray-100 px-3 py-2 text-left font-semibold text-gray-600 w-20 border-b border-gray-200">
                  ID
                </th>
                <th class="sticky left-20 bg-gray-100 px-3 py-2 text-left font-semibold text-gray-600 w-24 border-b border-gray-200">
                  Name
                </th>
                <%= for {_idx, start_date, _end_date} <- @slots do %>
                  <th class="px-1 py-2 text-center font-medium text-gray-500 border-b border-gray-200 min-w-[56px]">
                    <%= Calendar.strftime(start_date, "%b %-d") %>
                  </th>
                <% end %>
              </tr>
            </thead>
            <tbody>
              <%= for {year, residents} <- visible_residents(@residents_by_year, @filter_year) do %>
                <tr class="bg-gray-50">
                  <td
                    colspan={2 + length(@slots)}
                    class="px-3 py-1.5 text-xs font-semibold text-gray-500 uppercase tracking-wide"
                  >
                    R<%= year %> Residents
                  </td>
                </tr>
                <%= for resident <- residents do %>
                  <tr class="hover:bg-gray-50 transition-colors border-b border-gray-100">
                    <td class="sticky left-0 bg-white px-3 py-1.5 font-mono text-gray-500 border-r border-gray-100 w-20">
                      <.link navigate={"/residents/#{resident.id}"} class="hover:text-blue-600">
                        <%= resident.position_code %>
                      </.link>
                    </td>
                    <td class="sticky left-20 bg-white px-3 py-1.5 text-gray-700 font-medium border-r border-gray-100 w-24">
                      <.link navigate={"/residents/#{resident.id}"} class="hover:text-blue-600">
                        <%= resident.name %>
                      </.link>
                    </td>
                    <%= for {slot_idx, _start, _end} <- @slots do %>
                      <td
                        class="px-0.5 py-0.5 text-center min-w-[56px]"
                        data-resident={resident.position_code}
                      >
                        <%= render_cell(resident, slot_idx, @filter_type) %>
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
      filter_year: nil,
      filter_type: nil
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

  defp visible_residents(residents_by_year, nil) do
    residents_by_year
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp visible_residents(residents_by_year, year) do
    residents_by_year
    |> Enum.filter(fn {y, _} -> y == year end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp rotation_for_slot(resident, slot_idx) do
    Enum.find(resident.rotations, &(&1.slot_index == slot_idx))
  end

  defp render_cell(resident, slot_idx, filter_type) do
    case rotation_for_slot(resident, slot_idx) do
      nil ->
        Phoenix.HTML.raw(~s(<span class="text-gray-200">–</span>))

      rotation ->
        if filter_type && rotation.rotation_type != filter_type do
          Phoenix.HTML.raw(~s(<span class="opacity-20 text-gray-400">#{abbrev(rotation.rotation_type)}</span>))
        else
          color = Rotations.rotation_type_color(rotation.rotation_type)

          Phoenix.HTML.raw(
            ~s(<span class="inline-block rounded px-1 py-0.5 text-xs font-medium #{color}">#{abbrev(rotation.rotation_type)}</span>)
          )
        end
    end
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

  defp filter_tab_class(current, value) do
    base = "px-3 py-1 rounded-full text-sm font-medium transition-colors"

    if current == value do
      "#{base} bg-blue-600 text-white"
    else
      "#{base} bg-gray-100 text-gray-700 hover:bg-gray-200"
    end
  end
end
