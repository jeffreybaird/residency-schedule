defmodule ResidencyScheduleWeb.CompareLive.Index do
  use ResidencyScheduleWeb, :live_view

  alias ResidencySchedule.Schedules
  alias ResidencySchedule.Residents
  alias ResidencySchedule.Rotations

  @impl true
  def mount(_params, _session, socket) do
    schedule = Schedules.latest_schedule()

    socket =
      if schedule do
        residents = Residents.list_residents_for_schedule(schedule.id)

        assign(socket,
          schedule: schedule,
          schedules: Schedules.list_schedules(),
          residents: residents,
          resident_a_id: nil,
          resident_b_id: nil,
          co_service_days: [],
          co_service_ranges: [],
          total_days: 0,
          shared_shifts_remaining: 0,
          today: Date.utc_today(),
          today_anchor_date_start: nil,
          summary: []
        )
      else
        assign(socket,
          schedule: nil,
          schedules: [],
          residents: [],
          resident_a_id: nil,
          resident_b_id: nil,
          co_service_days: [],
          co_service_ranges: [],
          total_days: 0,
          shared_shifts_remaining: 0,
          today: Date.utc_today(),
          today_anchor_date_start: nil,
          summary: []
        )
      end

    {:ok, socket}
  end

  @impl true
  def handle_event("select_schedule", %{"id" => id}, socket) do
    schedule = Schedules.get_schedule!(String.to_integer(id))
    residents = Residents.list_residents_for_schedule(schedule.id)

    {:noreply,
     assign(socket,
       schedule: schedule,
       residents: residents,
       resident_a_id: nil,
       resident_b_id: nil,
       co_service_days: [],
       co_service_ranges: [],
       total_days: 0,
       shared_shifts_remaining: 0,
       today: Date.utc_today(),
       today_anchor_date_start: nil,
       summary: []
     )}
  end

  @impl true
  def handle_event("select_resident_a", %{"resident_id" => id}, socket) do
    resident_a_id = parse_id(id)
    socket = assign(socket, resident_a_id: resident_a_id)
    {:noreply, maybe_load_comparison(socket)}
  end

  @impl true
  def handle_event("select_resident_b", %{"resident_id" => id}, socket) do
    resident_b_id = parse_id(id)
    socket = assign(socket, resident_b_id: resident_b_id)
    {:noreply, maybe_load_comparison(socket)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-10 px-4">
      <%!-- Non-sticky: title + schedule switcher --%>
      <div class="flex items-center justify-between mb-4">
        <h1 class="text-2xl font-bold text-gray-800">Compare Schedules</h1>
        <%= if length(@schedules) > 1 do %>
          <div class="flex items-center gap-2">
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
      </div>

      <%= if @schedule do %>
        <%!-- Sticky: dropdowns + stats card --%>
        <div id="sticky-stats" class="sticky top-14 z-40 bg-white -mx-4 px-4 py-2 mb-4 shadow-[0_4px_8px_rgba(0,0,0,0.06)]">
          <div class="border-2 border-gray-300 rounded-xl overflow-hidden">
            <%!-- Card header --%>
            <div class="px-4 py-2 bg-gray-50 border-b-2 border-gray-300">
              <span class="text-xs font-semibold uppercase tracking-widest text-gray-500">
                Compare Residents
              </span>
            </div>

            <%!-- Dropdowns --%>
            <div class="grid grid-cols-2 divide-x divide-gray-200">
              <div class="px-4 py-3">
                <p class="text-xs font-medium text-gray-400 uppercase tracking-wide mb-1">Resident A</p>
                <form phx-change="select_resident_a">
                  <select
                    name="resident_id"
                    class="w-full border border-gray-200 rounded-md px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                  >
                    <option value="">Select a resident…</option>
                    <%= for r <- @residents do %>
                      <option value={r.id} selected={@resident_a_id == r.id}>
                        <%= r.name %> (<%= r.position_code %>)
                      </option>
                    <% end %>
                  </select>
                </form>
              </div>
              <div class="px-4 py-3">
                <p class="text-xs font-medium text-gray-400 uppercase tracking-wide mb-1">Resident B</p>
                <form phx-change="select_resident_b">
                  <select
                    name="resident_id"
                    class="w-full border border-gray-200 rounded-md px-2 py-1.5 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
                  >
                    <option value="">Select a resident…</option>
                    <%= for r <- @residents do %>
                      <option value={r.id} selected={@resident_b_id == r.id}>
                        <%= r.name %> (<%= r.position_code %>)
                      </option>
                    <% end %>
                  </select>
                </form>
              </div>
            </div>

            <%!-- Stats row (only when both residents selected) --%>
            <%= if @resident_a_id && @resident_b_id do %>
              <div class="grid grid-cols-2 divide-x divide-gray-100 border-t-2 border-gray-300">
                <div class="px-4 py-3">
                  <p class="text-xs font-medium text-gray-400 uppercase tracking-wide mb-0.5">
                    Shared Shifts
                  </p>
                  <p class="text-xl font-bold text-gray-800"><%= @total_days %></p>
                </div>
                <div class="px-4 py-3">
                  <p class="text-xs font-medium text-gray-400 uppercase tracking-wide mb-0.5">
                    Shared Shifts Remaining
                  </p>
                  <p class="text-xl font-bold text-gray-800"><%= @shared_shifts_remaining %></p>
                </div>
              </div>
            <% end %>
          </div>
        </div>

        <%= if @resident_a_id && @resident_b_id do %>
          <%= if @summary != [] do %>
            <div class="mb-4 -mx-4">
              <table class="min-w-full divide-y divide-gray-200 text-sm">
                <thead class="bg-gray-50 border-t border-gray-200">
                  <tr>
                    <th class="px-4 py-3 text-left font-semibold text-gray-600">Service</th>
                    <th class="px-4 py-3 text-right font-semibold text-gray-600">Days</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-100">
                  <%= for {type, days} <- @summary do %>
                    <% color = Rotations.rotation_type_color(type) %>
                    <tr>
                      <td class="px-4 py-2">
                        <span class={"inline-block rounded px-2 py-0.5 text-xs font-medium #{color}"}>
                          <%= Rotations.rotation_type_label(type) %>
                        </span>
                      </td>
                      <td class="px-4 py-2 text-right text-gray-700">
                        <%= days %>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>

          <%= if @co_service_ranges != [] do %>
            <div id="co-service-table" phx-hook="ScrollToToday" class="-mx-4">
              <table class="min-w-full divide-y divide-gray-200 text-sm">
                <thead class="bg-gray-50 border-t border-gray-200">
                  <tr>
                    <th class="px-4 py-3 text-left font-semibold text-gray-600">Dates</th>
                    <th class="px-4 py-3 text-left font-semibold text-gray-600">Service</th>
                    <th class="px-4 py-3 text-right font-semibold text-gray-600">Days</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-100">
                  <%= for range <- @co_service_ranges do %>
                    <% past = Date.compare(range.date_end, @today) == :lt %>
                    <% color = Rotations.rotation_type_color(range.rotation_type) %>
                    <tr
                      data-today-anchor={if range.date_start == @today_anchor_date_start, do: "true"}
                      class={[
                        if(past, do: "opacity-40"),
                        if(past,
                          do: nil,
                          else: "hover:bg-gray-100 hover:shadow-sm hover:relative hover:z-20 transition-colors"
                        )
                      ]}
                    >
                      <td class="px-4 py-2 text-gray-700">
                        <%= date_range_label(range.date_start, range.date_end) %>
                      </td>
                      <td class="px-4 py-2">
                        <span class={"inline-block rounded px-2 py-0.5 text-xs font-medium #{color}"}>
                          <%= Rotations.rotation_type_label(range.rotation_type) %>
                        </span>
                      </td>
                      <td class="px-4 py-2 text-right text-gray-500">
                        <%= Date.diff(range.date_end, range.date_start) + 1 %>
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% else %>
            <p class="text-center text-gray-400 py-8">No shared shifts found.</p>
          <% end %>
        <% end %>
      <% else %>
        <div class="text-center py-20">
          <p class="text-gray-500 mb-4">No schedule uploaded yet.</p>
          <.link
            navigate="/upload"
            class="bg-blue-600 text-white px-4 py-2 rounded-md hover:bg-blue-700"
          >
            Upload a Schedule
          </.link>
        </div>
      <% end %>
    </div>
    """
  end

  defp maybe_load_comparison(%{assigns: %{resident_a_id: nil}} = socket), do: socket
  defp maybe_load_comparison(%{assigns: %{resident_b_id: nil}} = socket), do: socket

  defp maybe_load_comparison(socket) do
    %{resident_a_id: a_id, resident_b_id: b_id} = socket.assigns
    today = Date.utc_today()
    co_service_days = Rotations.list_co_service_days(a_id, b_id)
    total_days = length(co_service_days)

    shared_shifts_remaining =
      Enum.count(co_service_days, fn %{date: d} -> Date.compare(d, today) != :lt end)

    summary =
      co_service_days
      |> Enum.group_by(& &1.rotation_type)
      |> Enum.map(fn {type, days} -> {type, length(days)} end)
      |> Enum.sort_by(&elem(&1, 1), :desc)

    co_service_ranges = merge_consecutive_days(co_service_days)

    today_anchor_date_start =
      case Enum.find(co_service_ranges, fn r -> Date.compare(r.date_end, today) != :lt end) do
        nil -> nil
        range -> range.date_start
      end

    assign(socket,
      co_service_days: co_service_days,
      co_service_ranges: co_service_ranges,
      total_days: total_days,
      shared_shifts_remaining: shared_shifts_remaining,
      today_anchor_date_start: today_anchor_date_start,
      summary: summary
    )
  end

  defp merge_consecutive_days(days) do
    days
    |> Enum.reduce([], fn %{date: date, rotation_type: type}, acc ->
      case acc do
        [%{date_end: prev_end, rotation_type: prev_type} = range | rest]
        when prev_type == type ->
          if Date.diff(date, prev_end) == 1 do
            [%{range | date_end: date} | rest]
          else
            [%{date_start: date, date_end: date, rotation_type: type} | acc]
          end

        _ ->
          [%{date_start: date, date_end: date, rotation_type: type} | acc]
      end
    end)
    |> Enum.reverse()
  end

  defp date_range_label(start, finish) when start == finish,
    do: Calendar.strftime(start, "%b %-d, %Y")

  defp date_range_label(start, finish),
    do: "#{Calendar.strftime(start, "%b %-d")} – #{Calendar.strftime(finish, "%b %-d, %Y")}"

  defp parse_id(""), do: nil
  defp parse_id(id), do: String.to_integer(id)
end
