defmodule ResidencyScheduleWeb.ResidentLive.Show do
  use ResidencyScheduleWeb, :live_view

  alias ResidencySchedule.Residents
  alias ResidencySchedule.Rotations

  @night_shift_types ~w[night_float highland_night_float strong_weekend_nights highland_weekend_nights]
  @non_shift_types ~w[vacation]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    resident = Residents.get_resident!(String.to_integer(id))
    today = Date.utc_today()

    schedule_start = schedule_start_date(resident.rotations)
    schedule_end = schedule_end_date(resident.rotations)
    night_shift_counts = count_night_shifts(resident.rotations)

    schedule_slots = Rotations.list_schedule_slots(resident.schedule_id)
    off_slots = compute_off_slots(resident.rotations, schedule_slots)
    all_entries = merge_entries(resident.rotations, off_slots)

    total_shifts = compute_total_shifts(resident.rotations)
    shifts_remaining = compute_shifts_remaining(resident.rotations, today)
    night_shifts_remaining = compute_night_shifts_remaining(resident.rotations, today)

    {:ok,
     assign(socket,
       resident: resident,
       schedule_start: schedule_start,
       schedule_end: schedule_end,
       night_shift_counts: night_shift_counts,
       all_entries: all_entries,
       total_shifts: total_shifts,
       shifts_remaining: shifts_remaining,
       night_shifts_remaining: night_shifts_remaining
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

        <%!-- Stats row --%>
        <div class="mb-6 grid grid-cols-3 gap-4">
          <div class="border rounded-xl px-5 py-4">
            <p class="text-xs font-medium text-gray-500 uppercase tracking-wide mb-1">
              Total Shifts
            </p>
            <p class="text-2xl font-bold text-gray-800"><%= @total_shifts %></p>
          </div>
          <div class="border rounded-xl px-5 py-4">
            <p class="text-xs font-medium text-gray-500 uppercase tracking-wide mb-1">
              Shifts Remaining
            </p>
            <p class="text-2xl font-bold text-gray-800"><%= @shifts_remaining %></p>
          </div>
          <div class="border rounded-xl px-5 py-4">
            <p class="text-xs font-medium text-gray-500 uppercase tracking-wide mb-1">
              Night Shifts Remaining
            </p>
            <p class="text-2xl font-bold text-gray-800"><%= @night_shifts_remaining %></p>
          </div>
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
              <%= for entry <- @all_entries do %>
                <% color = entry_color(entry.rotation_type) %>
                <% label = entry_label(entry.rotation_type) %>
                <tr class={if entry.rotation_type == "off", do: "bg-gray-50", else: "hover:bg-gray-50"}>
                  <td class="px-4 py-2">
                    <span class={"inline-block rounded px-2 py-0.5 text-xs font-medium #{color}"}>
                      <%= label %>
                    </span>
                  </td>
                  <td class={["px-4 py-2", if(entry.rotation_type == "off", do: "text-gray-400", else: "text-gray-700")]}>
                    <%= Calendar.strftime(entry.start_date, "%b %-d, %Y") %>
                  </td>
                  <td class={["px-4 py-2", if(entry.rotation_type == "off", do: "text-gray-400", else: "text-gray-700")]}>
                    <%= Calendar.strftime(entry.end_date, "%b %-d, %Y") %>
                  </td>
                  <td class={["px-4 py-2 text-right", if(entry.rotation_type == "off", do: "text-gray-400", else: "text-gray-500")]}>
                    <%= Date.diff(entry.end_date, entry.start_date) + 1 %>
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

  # --- Private helpers ---

  defp entry_color("off"), do: "bg-gray-100 text-gray-400"
  defp entry_color(rotation_type), do: Rotations.rotation_type_color(rotation_type)

  defp entry_label("off"), do: "OFF"
  defp entry_label(rotation_type), do: Rotations.rotation_type_label(rotation_type)

  defp compute_off_slots(rotations, schedule_slots) do
    resident_slot_indices = MapSet.new(rotations, & &1.slot_index)

    schedule_slots
    |> Enum.reject(fn {slot_index, _start, _end} ->
      MapSet.member?(resident_slot_indices, slot_index)
    end)
    |> Enum.map(fn {slot_index, start_date, end_date} ->
      %{slot_index: slot_index, start_date: start_date, end_date: end_date, rotation_type: "off"}
    end)
  end

  defp merge_entries(rotations, off_slots) do
    rotation_maps =
      Enum.map(rotations, fn r ->
        %{
          slot_index: r.slot_index,
          start_date: r.start_date,
          end_date: r.end_date,
          rotation_type: r.rotation_type
        }
      end)

    (rotation_maps ++ off_slots)
    |> Enum.sort_by(& &1.start_date, Date)
  end

  defp compute_total_shifts(rotations) do
    rotations
    |> Enum.reject(fn r -> r.rotation_type in @non_shift_types end)
    |> Enum.map(fn r -> Date.diff(r.end_date, r.start_date) + 1 end)
    |> Enum.sum()
  end

  defp compute_shifts_remaining(rotations, today) do
    rotations
    |> Enum.reject(fn r -> r.rotation_type in @non_shift_types end)
    |> Enum.reject(fn r -> Date.compare(r.end_date, today) == :lt end)
    |> Enum.map(fn r ->
      effective_start = Enum.max([r.start_date, today], Date)
      Date.diff(r.end_date, effective_start) + 1
    end)
    |> Enum.sum()
  end

  defp compute_night_shifts_remaining(rotations, today) do
    rotations
    |> Enum.filter(fn r -> r.rotation_type in @night_shift_types end)
    |> Enum.reject(fn r -> Date.compare(r.end_date, today) == :lt end)
    |> Enum.map(fn r ->
      effective_start = Enum.max([r.start_date, today], Date)
      Date.diff(r.end_date, effective_start) + 1
    end)
    |> Enum.sum()
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
