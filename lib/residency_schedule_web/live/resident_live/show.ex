defmodule ResidencyScheduleWeb.ResidentLive.Show do
  use ResidencyScheduleWeb, :live_view

  alias ResidencySchedule.Residents
  alias ResidencySchedule.Rotations

  @night_shift_types ~w[night_float highland_night_float strong_weekend_nights highland_weekend_nights]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    resident = Residents.get_resident!(String.to_integer(id))
    schedule_start = schedule_start_date(resident.rotations)
    schedule_end = schedule_end_date(resident.rotations)
    night_shift_counts = count_night_shifts(resident.rotations)

    {:ok,
     assign(socket,
       resident: resident,
       schedule_start: schedule_start,
       schedule_end: schedule_end,
       night_shift_counts: night_shift_counts
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-10 px-4">
      <div class="mb-8">
        <h1 class="text-2xl font-bold text-gray-800">
          <%= @resident.name %>
          <span class="text-base font-normal text-gray-500">(<%= @resident.position_code %>)</span>
        </h1>
      </div>

      <%= if @schedule_start && @schedule_end do %>
        <div class="mb-6 text-sm text-gray-500">
          <%= Calendar.strftime(@schedule_start, "%B %-d, %Y") %> –
          <%= Calendar.strftime(@schedule_end, "%B %-d, %Y") %>
          &nbsp;·&nbsp;
          <a
            href={"/residents/#{@resident.id}/calendar.ics"}
            class="text-blue-600 hover:text-blue-800"
          >
            Download .ics
          </a>
        </div>

        <%!-- Night shift summary --%>
        <%= if @night_shift_counts != [] do %>
          <div class="mb-6 border rounded-xl overflow-hidden">
            <div class="px-4 py-3 bg-gray-50 border-b border-gray-200">
              <h2 class="text-sm font-semibold text-gray-700">Night Shifts</h2>
            </div>
            <div class="divide-y divide-gray-100">
              <%= for {type, days} <- @night_shift_counts do %>
                <% color = Rotations.rotation_type_color(type) %>
                <div class="flex items-center justify-between px-4 py-3">
                  <span class={"inline-block rounded px-2 py-0.5 text-xs font-medium #{color}"}>
                    <%= Rotations.rotation_type_label(type) %>
                  </span>
                  <span class="text-sm font-semibold text-gray-700">
                    <%= days %> day<%= if days != 1, do: "s" %>
                  </span>
                </div>
              <% end %>
              <div class="flex items-center justify-between px-4 py-3 bg-gray-50">
                <span class="text-sm font-medium text-gray-600">Total</span>
                <span class="text-sm font-bold text-gray-800">
                  <%= @night_shift_counts |> Enum.map(&elem(&1, 1)) |> Enum.sum() %> days
                </span>
              </div>
            </div>
          </div>
        <% end %>

        <div class="border rounded-xl overflow-hidden">
          <table class="min-w-full divide-y divide-gray-200 text-sm">
            <thead class="bg-gray-50">
              <tr>
                <th class="px-4 py-3 text-left font-semibold text-gray-600">Rotation</th>
                <th class="px-4 py-3 text-left font-semibold text-gray-600">Start</th>
                <th class="px-4 py-3 text-left font-semibold text-gray-600">End</th>
                <th class="px-4 py-3 text-right font-semibold text-gray-600">Days</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <%= for rotation <- @resident.rotations do %>
                <% color = Rotations.rotation_type_color(rotation.rotation_type) %>
                <% label = Rotations.rotation_type_label(rotation.rotation_type) %>
                <tr class="hover:bg-gray-50">
                  <td class="px-4 py-2">
                    <span class={"inline-block rounded px-2 py-0.5 text-xs font-medium #{color}"}>
                      <%= label %>
                    </span>
                  </td>
                  <td class="px-4 py-2 text-gray-700">
                    <%= Calendar.strftime(rotation.start_date, "%b %-d, %Y") %>
                  </td>
                  <td class="px-4 py-2 text-gray-700">
                    <%= Calendar.strftime(rotation.end_date, "%b %-d, %Y") %>
                  </td>
                  <td class="px-4 py-2 text-right text-gray-500">
                    <%= Date.diff(rotation.end_date, rotation.start_date) + 1 %>
                  </td>
                </tr>
              <% end %>
            </tbody>
          </table>
        </div>
      <% else %>
        <p class="text-gray-500">No rotations recorded for this resident.</p>
      <% end %>
    </div>
    """
  end

  defp schedule_start_date([]), do: nil
  defp schedule_start_date(rotations), do: rotations |> Enum.map(& &1.start_date) |> Enum.min(Date)

  defp schedule_end_date([]), do: nil
  defp schedule_end_date(rotations), do: rotations |> Enum.map(& &1.end_date) |> Enum.max(Date)

  defp count_night_shifts(rotations) do
    rotations
    |> Enum.filter(&(&1.rotation_type in @night_shift_types))
    |> Enum.group_by(& &1.rotation_type)
    |> Enum.map(fn {type, rots} ->
      days = rots |> Enum.map(fn r -> Date.diff(r.end_date, r.start_date) + 1 end) |> Enum.sum()
      {type, days}
    end)
    |> Enum.sort_by(fn {type, _} -> Enum.find_index(@night_shift_types, &(&1 == type)) end)
  end
end
