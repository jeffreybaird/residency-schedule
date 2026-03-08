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
       total_days: 0,
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
      <div class="flex items-center justify-between mb-6">
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
        <div class="grid grid-cols-2 gap-6 mb-8">
          <div>
            <label class="block text-sm font-medium text-gray-700 mb-2">Resident A</label>
            <form phx-change="select_resident_a">
              <select
                name="resident_id"
                class="w-full border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
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

          <div>
            <label class="block text-sm font-medium text-gray-700 mb-2">Resident B</label>
            <form phx-change="select_resident_b">
              <select
                name="resident_id"
                class="w-full border border-gray-300 rounded-md px-3 py-2 text-sm focus:outline-none focus:ring-2 focus:ring-blue-500"
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

        <%= if @resident_a_id && @resident_b_id do %>
          <div class="mb-6 p-4 bg-blue-50 border border-blue-100 rounded-xl text-center">
            <p class="text-2xl font-bold text-blue-700"><%= @total_days %></p>
            <p class="text-sm text-blue-600">days working the same service together</p>
          </div>

          <%= if @summary != [] do %>
            <div class="mb-6 border rounded-xl overflow-hidden">
              <table class="min-w-full divide-y divide-gray-200 text-sm">
                <thead class="bg-gray-50">
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
            <div class="border rounded-xl overflow-hidden">
              <table class="min-w-full divide-y divide-gray-200 text-sm">
                <thead class="bg-gray-50">
                  <tr>
                    <th class="px-4 py-3 text-left font-semibold text-gray-600">Dates</th>
                    <th class="px-4 py-3 text-left font-semibold text-gray-600">Service</th>
                    <th class="px-4 py-3 text-right font-semibold text-gray-600">Days</th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-100">
                  <%= for range <- @co_service_ranges do %>
                    <% color = Rotations.rotation_type_color(range.rotation_type) %>
                    <tr class="hover:bg-gray-50">
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
            <p class="text-center text-gray-400 py-8">No shared service days found.</p>
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
    co_service_days = Rotations.list_co_service_days(a_id, b_id)
    total_days = length(co_service_days)

    summary =
      co_service_days
      |> Enum.group_by(& &1.rotation_type)
      |> Enum.map(fn {type, days} -> {type, length(days)} end)
      |> Enum.sort_by(&elem(&1, 1), :desc)

    co_service_ranges = merge_consecutive_days(co_service_days)

    assign(socket,
      co_service_days: co_service_days,
      co_service_ranges: co_service_ranges,
      total_days: total_days,
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
