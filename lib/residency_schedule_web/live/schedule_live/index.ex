defmodule ResidencyScheduleWeb.ScheduleLive.Index do
  use ResidencyScheduleWeb, :live_view

  alias ResidencySchedule.Schedules
  alias ResidencySchedule.Residents
  alias ResidencySchedule.Rotations

  # Fixed pixel widths for sticky label columns — must match left-[Xpx] values below.
  @id_col_px 72
  @name_col_px 128

  @impl true
  def mount(_params, session, socket) do
    schedules = Schedules.list_schedules()
    is_admin = session["admin"] == true

    socket =
      if schedules != [] do
        load_all_schedules(socket, schedules)
      else
        assign(socket,
          schedules: [],
          schedule_sections: [],
          all_slots: [],
          filter_year: nil
        )
      end

    {:ok,
     assign(socket,
       delete_confirm_id: nil,
       delete_error: nil,
       is_admin: is_admin,
       today: Date.utc_today()
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("scroll_to_schedule", %{"id" => id}, socket) do
    {:noreply, push_event(socket, "scroll-to-schedule", %{schedule_id: id})}
  end

  @impl true
  def handle_event("filter_year", %{"year" => year}, socket) do
    filter_year = if year == "all", do: nil, else: String.to_integer(year)
    {:noreply, assign(socket, filter_year: filter_year)}
  end

  @impl true
  def handle_event("request_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, delete_confirm_id: String.to_integer(id), delete_error: nil)}
  end

  @impl true
  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, delete_confirm_id: nil, delete_error: nil)}
  end

  @impl true
  def handle_event("delete_schedule", %{"schedule_id" => id, "password" => password}, socket) do
    expected = Application.fetch_env!(:residency_schedule, :delete_password)

    if password == expected do
      Schedules.delete_schedule(String.to_integer(id))
      remaining = Schedules.list_schedules()

      socket =
        case remaining do
          [] ->
            assign(socket,
              schedules: [],
              schedule_sections: [],
              all_slots: [],
              filter_year: nil
            )

          _ ->
            load_all_schedules(socket, remaining)
        end

      {:noreply, assign(socket, delete_confirm_id: nil, delete_error: nil)}
    else
      {:noreply, assign(socket, delete_error: "Incorrect password.")}
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :id_col_px, @id_col_px)
    assigns = assign(assigns, :name_col_px, @name_col_px)

    ~H"""
    <div class="min-h-screen bg-gray-50">
      <%= if @schedules != [] do %>
        <div class="bg-white border-b border-gray-200 px-4 sm:px-6 py-2 flex items-center gap-3 flex-wrap">
          <span class="text-sm text-gray-500">Schedule:</span>
          <%= for s <- @schedules do %>
            <div class="flex items-center gap-0.5">
              <button
                phx-click="scroll_to_schedule"
                phx-value-id={s.id}
                class={[
                  "px-3 py-1 text-sm font-medium transition-colors",
                  if(@is_admin, do: "rounded-l-full", else: "rounded-full"),
                  "bg-gray-100 text-gray-700 hover:bg-gray-200"
                ]}
                data-schedule-pill={s.id}
              >
                {s.label}
              </button>
              <%= if @is_admin do %>
                <button
                  phx-click="request_delete"
                  phx-value-id={s.id}
                  class="px-1.5 py-1 rounded-r-full text-sm font-medium transition-colors bg-gray-200 text-gray-500 hover:bg-red-100 hover:text-red-700"
                  title={"Delete #{s.label}"}
                >
                  &times;
                </button>
              <% end %>
            </div>
          <% end %>

          <%= if @delete_confirm_id do %>
            <% target = Enum.find(@schedules, &(&1.id == @delete_confirm_id)) %>
            <form
              phx-submit="delete_schedule"
              class="flex items-center gap-2 ml-2 pl-3 border-l border-gray-200"
            >
              <input type="hidden" name="schedule_id" value={@delete_confirm_id} />
              <span class="text-sm text-red-700 font-medium">
                Delete {target && target.label}?
              </span>
              <input
                type="password"
                name="password"
                placeholder="Password"
                autofocus
                class="border border-gray-300 rounded px-2 py-0.5 text-sm w-32 focus:outline-none focus:ring-1 focus:ring-red-400"
              />
              <%= if @delete_error do %>
                <span class="text-xs text-red-600">{@delete_error}</span>
              <% end %>
              <button
                type="submit"
                class="px-3 py-0.5 bg-red-600 text-white rounded text-sm font-medium hover:bg-red-700 transition-colors"
              >
                Delete
              </button>
              <button
                type="button"
                phx-click="cancel_delete"
                class="px-3 py-0.5 bg-gray-100 text-gray-700 rounded text-sm font-medium hover:bg-gray-200 transition-colors"
              >
                Cancel
              </button>
            </form>
          <% end %>
        </div>
      <% end %>

      <%= if @all_slots != [] do %>
        <div class="px-4 sm:px-6 py-4 flex flex-wrap items-center gap-4 border-b border-gray-200 bg-white">
          <div class="flex flex-wrap items-center gap-2">
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
                R{y}
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
          <table class="border-separate border-spacing-0 text-xs">
            <thead>
              <tr class="bg-gray-100 sticky top-0 z-30">
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
                <%= for {schedule_id, _idx, start_date, end_date, first_in_schedule?} <- @all_slots do %>
                  <% slot_past = Date.compare(end_date, @today) == :lt %>
                  <% slot_today = not slot_past and Date.compare(start_date, @today) != :gt %>
                  <th
                    class={[
                      "px-1 py-2 text-center font-medium border-b border-gray-200 whitespace-nowrap",
                      if(slot_past, do: "text-gray-300", else: "text-gray-500"),
                      if(first_in_schedule? and schedule_id != elem(hd(@all_slots), 0),
                        do: "border-l-2 border-l-blue-300",
                        else: ""
                      )
                    ]}
                    style="min-width: 52px"
                    data-slot-year={start_date.year}
                    data-today-slot={if slot_today, do: "true"}
                    data-schedule-id={schedule_id}
                    data-schedule-start={if first_in_schedule?, do: schedule_id}
                  >
                    {slot_header_label(start_date, end_date)}
                  </th>
                <% end %>
              </tr>
            </thead>
            <tbody>
              <%= for section <- @schedule_sections do %>
                <%= for {year, residents} <- visible_residents(section.residents_by_year, @filter_year) do %>
                  <tr class="bg-gray-50">
                    <td
                      colspan={2 + length(@all_slots)}
                      class="px-3 py-1 text-xs font-semibold text-gray-500 uppercase tracking-wide border-b border-gray-200"
                    >
                      {section.schedule.label} · R{year} Residents
                    </td>
                  </tr>
                  <%= for resident <- residents do %>
                    <tr class="hover:bg-gray-50 transition-colors border-b border-gray-100">
                      <td
                        class="sticky left-0 z-20 bg-white px-2 py-1 font-mono text-gray-500 border-r border-gray-200 overflow-hidden"
                        style={"width: #{@id_col_px}px; min-width: #{@id_col_px}px; max-width: #{@id_col_px}px"}
                      >
                        <.link navigate={"/residents/#{resident.id}"} class="hover:text-blue-600">
                          {resident.position_code}
                        </.link>
                      </td>
                      <td
                        class="sticky z-20 bg-white px-2 py-1 text-gray-700 font-medium border-r border-gray-200 overflow-hidden"
                        style={"left: #{@id_col_px}px; width: #{@name_col_px}px; min-width: #{@name_col_px}px; max-width: #{@name_col_px}px"}
                      >
                        <.link
                          navigate={"/residents/#{resident.id}"}
                          class="hover:text-blue-600 truncate block"
                        >
                          {resident.name}
                        </.link>
                      </td>
                      <%!-- Empty cells for slots before this schedule --%>
                      <%= if section.slot_offset > 0 do %>
                        <td colspan={section.slot_offset} class="px-0.5 py-0.5"></td>
                      <% end %>
                      <%!-- Rotation cells for this schedule's slots --%>
                      <%= for {colspan, rotation} <- cell_groups(section.slots, resident.rotations) do %>
                        <% past = rotation != nil && Date.compare(rotation.end_date, @today) == :lt %>
                        <td
                          colspan={colspan}
                          class="px-0.5 py-0.5 text-center border-r border-gray-100"
                        >
                          {render_rotation_cell(rotation, past)}
                        </td>
                      <% end %>
                      <%!-- Empty cells for slots after this schedule --%>
                      <% trailing = length(@all_slots) - section.slot_offset - length(section.slots) %>
                      <%= if trailing > 0 do %>
                        <td colspan={trailing} class="px-0.5 py-0.5"></td>
                      <% end %>
                    </tr>
                  <% end %>
                <% end %>
              <% end %>
            </tbody>
          </table>
        </div>
      <% else %>
        <div class="flex flex-col items-center justify-center py-24 text-center">
          <p class="text-gray-500 mb-4">No schedule uploaded yet.</p>
          <%= if @is_admin do %>
            <.link
              navigate="/admin/upload"
              class="bg-blue-600 text-white px-4 py-2 rounded-md hover:bg-blue-700 transition-colors"
            >
              Upload a Schedule
            </.link>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  # --- Private helpers ---

  @doc false
  def load_all_schedules(socket, schedules) do
    {sections, _offset} =
      schedules
      |> Enum.map(&build_section/1)
      |> Enum.map_reduce(0, fn section, offset ->
        {%{section | slot_offset: offset}, offset + length(section.slots)}
      end)

    all_slots = build_combined_slots(sections)

    assign(socket,
      schedules: schedules,
      schedule_sections: sections,
      all_slots: all_slots,
      filter_year: nil
    )
  end

  defp build_section(schedule) do
    residents = fetch_residents_with_rotations(schedule.id)

    %{
      schedule: schedule,
      residents_by_year: group_residents_by_year(residents),
      slots: build_slots(residents),
      slot_offset: 0
    }
  end

  @doc """
  Builds a flat list of all slots across all schedule sections, annotated with
  schedule_id and whether each slot is the first in its schedule.

      iex> sections = [
      ...>   %{schedule: %{id: 1}, slots: [{0, ~D[2023-07-03], ~D[2023-07-09]}]},
      ...>   %{schedule: %{id: 2}, slots: [{0, ~D[2024-07-01], ~D[2024-07-07]}]}
      ...> ]
      iex> ResidencyScheduleWeb.ScheduleLive.Index.build_combined_slots(sections)
      [{1, 0, ~D[2023-07-03], ~D[2023-07-09], true}, {2, 0, ~D[2024-07-01], ~D[2024-07-07], true}]
  """
  def build_combined_slots(sections) do
    Enum.flat_map(sections, fn section ->
      section.slots
      |> Enum.with_index()
      |> Enum.map(fn {{idx, start_date, end_date}, i} ->
        {section.schedule.id, idx, start_date, end_date, i == 0}
      end)
    end)
  end

  defp fetch_residents_with_rotations(schedule_id) do
    schedule_id
    |> Residents.list_residents_for_schedule()
    |> Enum.map(&load_rotations/1)
  end

  defp group_residents_by_year(residents) do
    Enum.group_by(residents, & &1.residency_year)
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

  defp render_rotation_cell(nil, _past) do
    Phoenix.HTML.raw(~s(<span class="text-gray-200">–</span>))
  end

  defp render_rotation_cell(rotation, past) do
    color = Rotations.rotation_type_color(rotation.rotation_type)
    opacity = if past, do: " opacity-40", else: ""

    Phoenix.HTML.raw(
      ~s(<span class="inline-block rounded px-1 py-0.5 text-xs font-medium whitespace-nowrap#{opacity} #{color}">#{abbrev(rotation.rotation_type)}</span>)
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
    "ultrasound" => "US",
    "unknown" => "?",
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
