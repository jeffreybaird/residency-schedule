defmodule ResidencyScheduleWeb.ResidentLive.Show do
  use ResidencyScheduleWeb, :live_view

  alias ResidencySchedule.Residents
  alias ResidencySchedule.Rotations

  @strong_night_types ~w[night_float strong_weekend_nights]
  @highland_night_types ~w[highland_night_float highland_weekend_nights]
  @night_shift_types @strong_night_types ++ @highland_night_types
  @non_shift_types ~w[vacation]

  @impl true
  def mount(%{"id" => id}, session, socket) do
    resident_id = session["resident_id"]
    resident = Residents.get_resident!(String.to_integer(id))
    today = Date.utc_today()

    year_history =
      resident.name
      |> Residents.list_by_canonical_name()
      |> Enum.map(&%{id: &1.id, label: &1.schedule.label, academic_year: &1.schedule.academic_year})

    schedule_start = schedule_start_date(resident.rotations)
    schedule_end = schedule_end_date(resident.rotations)
    night_shift_counts = count_night_shifts(resident.rotations)

    schedule_slots = Rotations.list_schedule_slots(resident.schedule_id)
    off_slots = compute_off_slots(resident.rotations, schedule_slots)
    all_entries = merge_entries(resident.rotations, off_slots)

    today_anchor_slot_index =
      case Enum.find(all_entries, fn e -> Date.compare(e.end_date, today) != :lt end) do
        nil -> nil
        entry -> entry.slot_index
      end

    total_shifts = compute_total_shifts(resident.rotations)
    shifts_remaining = compute_shifts_remaining(resident.rotations, today)
    night_shifts_remaining_strong = compute_night_shifts_remaining(resident.rotations, today, @strong_night_types)
    night_shifts_remaining_highland = compute_night_shifts_remaining(resident.rotations, today, @highland_night_types)

    {:ok,
     assign(socket,
       resident: resident,
       year_history: year_history,
       is_home_resident: resident_id == String.to_integer(id),
       schedule_start: schedule_start,
       schedule_end: schedule_end,
       night_shift_counts: night_shift_counts,
       all_entries: all_entries,
       today: today,
       today_anchor_slot_index: today_anchor_slot_index,
       total_shifts: total_shifts,
       shifts_remaining: shifts_remaining,
       night_shifts_remaining_strong: night_shifts_remaining_strong,
       night_shifts_remaining_highland: night_shifts_remaining_highland,
       stats_expanded: true,
       night_shifts_expanded: false
     )}
  end

  @impl true
  def handle_event("toggle_stats", _params, socket) do
    {:noreply, assign(socket, stats_expanded: !socket.assigns.stats_expanded)}
  end

  @impl true
  def handle_event("toggle_night_shifts", _params, socket) do
    {:noreply, assign(socket, night_shifts_expanded: !socket.assigns.night_shifts_expanded)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-10 px-4">
      <div class="mb-4">
        <h1 class="text-2xl font-bold text-gray-800">
          <%= @resident.name %>
          <span
            class="text-base font-normal text-gray-500"
            title={"Year #{@resident.residency_year}, resident #{@resident.schedule_number}"}
          >(<%= @resident.position_code %>)</span>
        </h1>
        <div class="flex items-center justify-between gap-2 mt-2">
          <div class="flex gap-2 flex-wrap">
            <%= for year <- @year_history do %>
              <%= if year.id == @resident.id do %>
                <span
                  class="px-3 py-1 rounded-full text-xs font-semibold bg-blue-600 text-white"
                  title="Currently viewing this year"
                >
                  <%= year.label %>
                </span>
              <% else %>
                <.link
                  navigate={"/residents/#{year.id}"}
                  class="px-3 py-1 rounded-full text-xs font-semibold bg-gray-100 text-gray-600 hover:bg-gray-200 transition-colors"
                  title={"View #{@resident.name}'s #{year.label} schedule"}
                >
                  <%= year.label %>
                </.link>
              <% end %>
            <% end %>
          </div>
          <%= if @is_home_resident do %>
            <div class="inline-flex items-center gap-1 shrink-0">
              <span class="inline-flex items-center gap-1 px-3 py-1 rounded-full text-xs font-semibold bg-green-100 text-green-700">
                ✓ My Resident
              </span>
              <form action="/unset-home" method="post" class="inline">
                <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
                <input type="hidden" name="resident_id" value={@resident.id} />
                <button
                  type="submit"
                  class="px-2 py-1 rounded-full text-xs text-gray-400 hover:bg-red-50 hover:text-red-500 transition-colors"
                  title="Remove My Resident — the nav link will no longer point here"
                >
                  ✕
                </button>
              </form>
            </div>
          <% else %>
            <form action={"/set-home/#{@resident.id}"} method="post" class="inline shrink-0">
              <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
              <button
                type="submit"
                class="px-3 py-1 rounded-full text-xs font-semibold bg-gray-100 text-gray-600 hover:bg-green-100 hover:text-green-700 transition-colors"
                title="Pin this resident — adds a My Resident shortcut to the nav"
              >
                Set as My Resident
              </button>
            </form>
          <% end %>
        </div>
      </div>

      <%= if @schedule_start && @schedule_end do %>
        <div class="mb-4 text-sm text-gray-500">
          <%= Calendar.strftime(@schedule_start, "%B %-d, %Y") %> –
          <%= Calendar.strftime(@schedule_end, "%B %-d, %Y") %>
          &nbsp;·&nbsp;
          <a
            href={"/residents/#{@resident.id}/calendar.ics"}
            class="text-blue-600 hover:text-blue-800"
            title="Download this schedule as an iCalendar file to import into Google Calendar, Apple Calendar, or Outlook"
          >
            Download .ics
          </a>
        </div>

        <%!-- Sticky stats container --%>
        <div id="sticky-stats" class="sticky top-14 z-40 bg-white mb-3">
          <div class="border-2 border-gray-300 rounded-xl overflow-y-auto max-h-[30vh]">
            <%!-- Card header: resident name + label + collapse toggle --%>
            <div class="flex items-center justify-between px-4 py-2 bg-gray-100 border-b-2 border-gray-300">
              <span class="text-xs font-semibold text-gray-600">
                <span class="text-gray-800"><%= @resident.name %></span>
                <span class="text-gray-400 mx-1">·</span>
                <span class="uppercase tracking-widest text-gray-500">Schedule Stats</span>
              </span>
              <button
                phx-click="toggle_stats"
                class={[
                  "flex items-center gap-1.5 text-xs font-medium rounded-full px-3 py-0.5 transition-colors",
                  if(@stats_expanded,
                    do: "bg-gray-200 text-gray-600 hover:bg-gray-300",
                    else: "bg-blue-50 text-blue-600 hover:bg-blue-100"
                  )
                ]}
              >
                <svg
                  class={["w-3 h-3 transition-transform", if(@stats_expanded, do: "rotate-90", else: "")]}
                  fill="currentColor"
                  viewBox="0 0 20 20"
                >
                  <path
                    fill-rule="evenodd"
                    d="M7.293 4.707a1 1 0 011.414 0l5 5a1 1 0 010 1.414l-5 5a1 1 0 01-1.414-1.414L11.586 10 7.293 5.707a1 1 0 010-1.414z"
                    clip-rule="evenodd"
                  />
                </svg>
                <%= if @stats_expanded, do: "Collapse", else: "Expand" %>
              </button>
            </div>

            <%= if @stats_expanded do %>
              <%!-- Stats grid: light grey fill, subtle internal dividers --%>
              <div class="grid grid-cols-2 divide-x divide-y divide-gray-200 bg-gray-50">
                <div class="px-4 py-3" title="Total scheduled service blocks (excludes vacation)">
                  <p class="text-xs font-medium text-gray-400 uppercase tracking-wide mb-0.5">
                    Total Shifts
                  </p>
                  <p class="text-xl font-bold text-gray-800"><%= @total_shifts %></p>
                </div>
                <div class="px-4 py-3" title="Service blocks with a start date on or after today">
                  <p class="text-xs font-medium text-gray-400 uppercase tracking-wide mb-0.5">
                    Shifts Remaining
                  </p>
                  <p class="text-xl font-bold text-gray-800"><%= @shifts_remaining %></p>
                </div>
                <div class="px-4 py-3" title="Night float and weekend night blocks at Strong Memorial remaining">
                  <p class="text-xs font-medium text-gray-400 uppercase tracking-wide mb-0.5">
                    Night Shifts Remaining – Strong
                  </p>
                  <p class="text-xl font-bold text-gray-800"><%= @night_shifts_remaining_strong %></p>
                </div>
                <div class="px-4 py-3" title="Night float and weekend night blocks at Highland remaining">
                  <p class="text-xs font-medium text-gray-400 uppercase tracking-wide mb-0.5">
                    Night Shifts Remaining – Highland
                  </p>
                  <p class="text-xl font-bold text-gray-800"><%= @night_shifts_remaining_highland %></p>
                </div>
              </div>

              <%!-- Night shift breakdown (expandable row inside the card) --%>
              <%= if @night_shift_counts != [] do %>
                <div class="border-t border-gray-200 bg-gray-50">
                  <button
                    phx-click="toggle_night_shifts"
                    class="flex items-center justify-between w-full px-4 py-2 text-xs font-medium text-gray-500 hover:bg-gray-100 hover:text-gray-700 transition-colors"
                  >
                    <span class="flex items-center gap-1.5">
                      <svg
                        class={["w-2.5 h-2.5 text-gray-400 transition-transform", if(@night_shifts_expanded, do: "rotate-90", else: "")]}
                        fill="currentColor"
                        viewBox="0 0 20 20"
                      >
                        <path
                          fill-rule="evenodd"
                          d="M7.293 4.707a1 1 0 011.414 0l5 5a1 1 0 010 1.414l-5 5a1 1 0 01-1.414-1.414L11.586 10 7.293 5.707a1 1 0 010-1.414z"
                          clip-rule="evenodd"
                        />
                      </svg>
                      Night Shift Breakdown
                    </span>
                    <span class={[
                      "rounded-full px-2 py-0.5 transition-colors",
                      if(@night_shifts_expanded,
                        do: "bg-gray-200 text-gray-600",
                        else: "bg-gray-100 text-gray-500"
                      )
                    ]}>
                      <%= if @night_shifts_expanded, do: "Collapse", else: "Expand" %>
                    </span>
                  </button>
                  <%= if @night_shifts_expanded do %>
                    <div class="divide-y divide-gray-100 border-t border-gray-100">
                      <%= for {type, days} <- @night_shift_counts do %>
                        <% color = Rotations.rotation_type_color(type) %>
                        <div class="flex items-center justify-between px-4 py-2">
                          <span class={"inline-block rounded px-2 py-0.5 text-xs font-medium #{color}"}>
                            <%= Rotations.rotation_type_label(type) %>
                          </span>
                          <span class="text-sm font-semibold text-gray-700">
                            <%= days %> day<%= if days != 1, do: "s" %>
                          </span>
                        </div>
                      <% end %>
                      <div class="flex items-center justify-between px-4 py-2 bg-gray-50">
                        <span class="text-sm font-medium text-gray-600">Total</span>
                        <span class="text-sm font-bold text-gray-800">
                          <%= @night_shift_counts |> Enum.map(&elem(&1, 1)) |> Enum.sum() %> days
                        </span>
                      </div>
                    </div>
                  <% end %>
                </div>
              <% end %>
            <% end %>
          </div>
        </div>

        <div id="rotation-table" phx-hook="ScrollToToday" class="border-2 border-gray-300 rounded-xl overflow-auto overscroll-contain">
          <table class="min-w-full divide-y divide-gray-200 text-sm">
            <thead class="sticky top-0 z-10 bg-gray-100">
              <tr>
                <th class="px-4 py-3 text-left font-semibold text-gray-600">Rotation</th>
                <th class="px-4 py-3 text-left font-semibold text-gray-600">Start</th>
                <th class="px-4 py-3 text-left font-semibold text-gray-600">End</th>
                <th class="px-4 py-3 text-right font-semibold text-gray-600">Days</th>
              </tr>
            </thead>
            <tbody class="divide-y divide-gray-100">
              <%= for entry <- @all_entries do %>
                <% past = Date.compare(entry.end_date, @today) == :lt %>
                <% color = entry_color(entry.rotation_type) %>
                <% label = entry_label(entry.rotation_type) %>
                <tr
                  data-today-anchor={if entry.slot_index == @today_anchor_slot_index, do: "true"}
                  class={entry_row_class(entry.rotation_type, past)}
                >
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

  defp entry_row_class("off", true), do: ["opacity-40", "bg-gray-50"]

  defp entry_row_class("off", false),
    do: ["bg-gray-50", "hover:bg-gray-100", "hover:shadow-sm", "hover:relative", "hover:z-20", "transition-colors"]

  defp entry_row_class(_type, true), do: "opacity-40"

  defp entry_row_class(_type, false),
    do: ["hover:bg-gray-100", "hover:shadow-sm", "hover:relative", "hover:z-20", "transition-colors"]

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

  defp compute_night_shifts_remaining(rotations, today, types) do
    rotations
    |> Enum.filter(fn r -> r.rotation_type in types end)
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
