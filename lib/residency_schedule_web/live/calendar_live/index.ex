defmodule ResidencyScheduleWeb.CalendarLive.Index do
  use ResidencyScheduleWeb, :live_view

  alias ResidencySchedule.Schedules
  alias ResidencySchedule.Rotations
  alias ResidencySchedule.ShiftOverrides

  @impl true
  def mount(_params, _session, socket) do
    any_schedules? = Schedules.list_schedules() != []
    current_month = Date.utc_today() |> Date.beginning_of_month()

    {rotation_index, override_index} =
      if any_schedules?,
        do: build_indexes(current_month),
        else: {%{}, %{}}

    {:ok,
     assign(socket,
       any_schedules?: any_schedules?,
       current_month: current_month,
       rotation_index: rotation_index,
       override_index: override_index,
       selected_date: nil,
       day_detail: []
     )}
  end

  @impl true
  def handle_event("prev_month", _params, socket) do
    new_month = Date.shift(socket.assigns.current_month, month: -1)
    {rotation_index, override_index} = build_indexes(new_month)

    {:noreply,
     assign(socket,
       current_month: new_month,
       rotation_index: rotation_index,
       override_index: override_index,
       selected_date: nil,
       day_detail: []
     )}
  end

  @impl true
  def handle_event("next_month", _params, socket) do
    new_month = Date.shift(socket.assigns.current_month, month: 1)
    {rotation_index, override_index} = build_indexes(new_month)

    {:noreply,
     assign(socket,
       current_month: new_month,
       rotation_index: rotation_index,
       override_index: override_index,
       selected_date: nil,
       day_detail: []
     )}
  end

  @impl true
  def handle_event("select_day", %{"date" => date_str}, socket) do
    date = Date.from_iso8601!(date_str)

    day_detail =
      build_effective_day_detail(
        date,
        Map.get(socket.assigns.rotation_index, date, []),
        Map.get(socket.assigns.override_index, date, [])
      )

    {:noreply, assign(socket, selected_date: date, day_detail: day_detail)}
  end

  @impl true
  def handle_event("close_modal", _params, socket) do
    {:noreply, assign(socket, selected_date: nil, day_detail: [])}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-10 px-4">
      <div class="flex flex-wrap items-center justify-between gap-3 mb-6">
        <h1 class="text-2xl font-bold text-gray-800">Calendar</h1>
      </div>

      <%= if @any_schedules? do %>
        <div class="flex items-center justify-between mb-4">
          <button
            phx-click="prev_month"
            class="px-3 py-1.5 rounded-md bg-gray-100 hover:bg-gray-200 text-sm font-medium transition-colors"
          >
            ← Prev
          </button>
          <h2 class="text-lg font-semibold text-gray-700">
            <%= Calendar.strftime(@current_month, "%B %Y") %>
          </h2>
          <button
            phx-click="next_month"
            class="px-3 py-1.5 rounded-md bg-gray-100 hover:bg-gray-200 text-sm font-medium transition-colors"
          >
            Next →
          </button>
        </div>

        <div class="grid grid-cols-7 gap-px bg-gray-200 border border-gray-200 rounded-xl overflow-hidden shadow-sm">
          <%= for {short, long} <- [{"Su","Sun"},{"Mo","Mon"},{"Tu","Tue"},{"We","Wed"},{"Th","Thu"},{"Fr","Fri"},{"Sa","Sat"}] do %>
            <div class="bg-gray-50 px-1 py-2 text-center text-xs font-semibold text-gray-500 uppercase tracking-wide">
              <span class="sm:hidden"><%= short %></span>
              <span class="hidden sm:inline"><%= long %></span>
            </div>
          <% end %>

          <%= for day <- calendar_days(@current_month) do %>
            <% in_month = day.month == @current_month.month %>
            <% rotations = Map.get(@rotation_index, day, []) %>
            <div
              phx-click="select_day"
              phx-value-date={Date.to_iso8601(day)}
              class={[
                "relative bg-white p-1 sm:p-2 h-14 sm:h-20 cursor-pointer border-0 transition-colors hover:bg-blue-50",
                if(in_month, do: "", else: "opacity-40")
              ]}
            >
              <span class={[
                "text-sm font-medium",
                if(day == Date.utc_today(), do: "text-blue-600 font-bold", else: "text-gray-700")
              ]}>
                <%= day.day %>
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

        <%!-- Day detail modal --%>
        <%= if @selected_date do %>
          <div class="fixed inset-0 z-50 flex items-center justify-center">
            <div phx-click="close_modal" class="absolute inset-0 bg-black/40"></div>
            <div class="relative bg-white rounded-xl shadow-2xl p-6 max-w-md w-full mx-4 z-10 max-h-[80vh] overflow-y-auto">
              <div class="flex items-start justify-between mb-4">
                <h3 class="text-lg font-semibold text-gray-800">
                  <%= Calendar.strftime(@selected_date, "%A, %B %-d, %Y") %>
                </h3>
                <button
                  phx-click="close_modal"
                  class="text-gray-400 hover:text-gray-600 text-xl leading-none ml-4"
                >
                  ✕
                </button>
              </div>

              <%= if @day_detail == [] do %>
                <p class="text-sm text-gray-400">No rotations recorded for this day.</p>
              <% else %>
                <div class="space-y-4">
                  <%= for {type, entries} <- @day_detail do %>
                    <% color = Rotations.rotation_type_color(type) %>
                    <div>
                      <div class="flex items-center gap-2 mb-2">
                        <span class={"inline-block rounded px-2 py-0.5 text-xs font-medium #{color}"}>
                          <%= Rotations.rotation_type_label(type) %>
                        </span>
                        <span class="text-xs text-gray-400">
                          <%= length(entries) %> resident<%= if length(entries) != 1, do: "s" %>
                        </span>
                      </div>
                      <ul class="space-y-1 pl-1">
                        <%= for entry <- entries do %>
                          <li class="flex items-center gap-2 text-sm">
                            <span class="text-xs text-gray-400 font-mono w-10">
                              <%= entry.resident.position_code %>
                            </span>
                            <.link
                              navigate={"/residents/#{entry.resident.id}"}
                              class={[
                                "hover:text-blue-600 hover:underline",
                                if(entry.overridden, do: "line-through text-gray-400", else: "text-gray-700")
                              ]}
                            >
                              <%= entry.resident.name %>
                            </.link>
                            <%= if entry.overridden do %>
                              <span class="text-xs text-gray-400 italic">
                                → <%= entry.covered_by.name %>
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

  # Builds both the rotation index (date → [rotation]) and the override index (date → [override]).
  defp build_indexes(current_month) do
    rotations = Rotations.list_rotations_for_month_all_schedules(current_month.year, current_month.month)
    overrides = ShiftOverrides.list_overrides_for_month(current_month.year, current_month.month)

    rotation_index =
      rotations
      |> Enum.flat_map(fn rot ->
        Date.range(rot.start_date, rot.end_date) |> Enum.map(&{&1, rot})
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    override_index =
      overrides
      |> Enum.flat_map(fn o ->
        Date.range(o.override_start_date, o.override_end_date) |> Enum.map(&{&1, o})
      end)
      |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))

    {rotation_index, override_index}
  end

  # Builds the effective day detail entries for the modal, reflecting overrides.
  # Each entry is %{resident, rotation_type, overridden, covered_by, is_coverage}.
  defp build_effective_day_detail(_date, rotations, overrides) do
    # Map rotation_id → override for fast lookup
    override_by_rotation = Map.new(overrides, fn o -> {o.rotation_id, o} end)

    # Set of covering resident IDs active today (they appear under the overridden rotation)
    covering_today = MapSet.new(overrides, & &1.covering_schedule_resident_id)

    effective =
      Enum.flat_map(rotations, fn rot ->
        if MapSet.member?(covering_today, rot.schedule_resident_id) do
          # This resident is covering someone else today — suppress from their own rotation
          []
        else
          case Map.get(override_by_rotation, rot.id) do
            nil ->
              [%{resident: rot.schedule_resident, rotation_type: rot.rotation_type, overridden: false, covered_by: nil, is_coverage: false}]

            override ->
              # Original resident is being covered — show crossed out, then the covering resident
              [
                %{resident: rot.schedule_resident, rotation_type: rot.rotation_type, overridden: true, covered_by: override.covering_schedule_resident, is_coverage: false},
                %{resident: override.covering_schedule_resident, rotation_type: rot.rotation_type, overridden: false, covered_by: nil, is_coverage: true}
              ]
          end
        end
      end)

    effective
    |> Enum.sort_by(fn e -> {e.rotation_type, e.resident.residency_year, e.resident.schedule_number} end)
    |> Enum.group_by(& &1.rotation_type)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp group_by_type(rotations) do
    rotations
    |> Enum.group_by(& &1.rotation_type)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp calendar_days(first_of_month) do
    last_of_month = Date.end_of_month(first_of_month)
    start_dow = Date.day_of_week(first_of_month, :sunday)
    grid_start = Date.add(first_of_month, -(start_dow - 1))

    end_dow = Date.day_of_week(last_of_month, :sunday)
    grid_end = Date.add(last_of_month, 7 - end_dow)

    Date.range(grid_start, grid_end) |> Enum.to_list()
  end

  defp dot_color(rotation_type) do
    Rotations.rotation_type_color(rotation_type)
    |> String.split()
    |> List.first()
  end
end
