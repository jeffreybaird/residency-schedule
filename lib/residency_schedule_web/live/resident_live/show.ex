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
      |> Enum.map(
        &%{id: &1.id, label: &1.schedule.label, academic_year: &1.schedule.academic_year}
      )

    schedule_start = schedule_start_date(resident.rotations)
    schedule_end = schedule_end_date(resident.rotations)
    night_shift_counts = count_night_shifts(resident.rotations)

    schedule_slots = Rotations.list_schedule_slots(resident.schedule_id)
    off_slots = compute_off_slots(resident.rotations, schedule_slots)
    effective_segs = Rotations.effective_segments_for_resident(resident.id)
    all_entries = merge_effective_entries(effective_segs, off_slots)
    available_services = build_service_options(all_entries)
    filtered_entries = filter_entries(all_entries, [])

    today_anchor_slot_index = today_anchor_slot_index(filtered_entries, today)

    total_shifts = compute_total_shifts(resident.rotations)
    shifts_remaining = compute_shifts_remaining(resident.rotations, today)

    night_shifts_remaining_strong =
      compute_night_shifts_remaining(resident.rotations, today, @strong_night_types)

    night_shifts_remaining_highland =
      compute_night_shifts_remaining(resident.rotations, today, @highland_night_types)

    {:ok,
     assign(socket,
       resident: resident,
       year_history: year_history,
       is_home_resident: resident_id == String.to_integer(id),
       schedule_start: schedule_start,
       schedule_end: schedule_end,
       night_shift_counts: night_shift_counts,
       all_entries: all_entries,
       filtered_entries: filtered_entries,
       available_services: available_services,
       service_filters: [],
       service_filter_open: false,
       today: today,
       today_anchor_slot_index: today_anchor_slot_index,
       total_shifts: total_shifts,
       shifts_remaining: shifts_remaining,
       night_shifts_remaining_strong: night_shifts_remaining_strong,
       night_shifts_remaining_highland: night_shifts_remaining_highland,
       stats_expanded: true,
       night_shifts_expanded: false,
       shift_coworkers_modal: nil
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
  def handle_event("toggle_service_filter", %{"service" => service}, socket) do
    service_filters =
      socket.assigns.service_filters
      |> toggle_service(service)
      |> normalize_service_filters(socket.assigns.available_services)

    {:noreply, assign_filtered_entries(socket, service_filters)}
  end

  @impl true
  def handle_event("clear_service_filters", _params, socket) do
    {:noreply, assign_filtered_entries(socket, [])}
  end

  @impl true
  def handle_event("toggle_service_filter_menu", _params, socket) do
    {:noreply, assign(socket, service_filter_open: !socket.assigns.service_filter_open)}
  end

  @impl true
  def handle_event("close_service_filter_menu", _params, socket) do
    {:noreply, assign(socket, service_filter_open: false)}
  end

  @impl true
  def handle_event("open_shift_coworkers", params, socket) do
    # phx-value-* keys are sent with hyphens (e.g. start-date), not underscores.
    type = params["rotation-type"] || params["rotation_type"]
    sd = params["start-date"] || params["start_date"]
    ed = params["end-date"] || params["end_date"]
    slot_raw = params["slot-index"] || params["slot_index"]

    cond do
      type == "off" and is_binary(sd) and is_binary(ed) and is_binary(slot_raw) ->
        with {:ok, start_d} <- Date.from_iso8601(sd),
             {:ok, end_d} <- Date.from_iso8601(ed),
             {slot_idx, ""} <- Integer.parse(slot_raw) do
          coworker_rows =
            Rotations.list_off_coworker_rows_for_slot_in_range(
              socket.assigns.resident.schedule_id,
              slot_idx,
              start_d,
              end_d
            )

          {:noreply,
           assign(socket,
             shift_coworkers_modal: %{
               rotation_type: "off",
               start_date: start_d,
               end_date: end_d,
               coworker_rows: coworker_rows
             }
           )}
        else
          _ -> {:noreply, socket}
        end

      is_binary(type) and type != "off" and is_binary(sd) and is_binary(ed) ->
        with {:ok, start_d} <- Date.from_iso8601(sd),
             {:ok, end_d} <- Date.from_iso8601(ed) do
          coworker_rows =
            Rotations.list_effective_coworker_rows_for_type_in_range(
              socket.assigns.resident.schedule_id,
              type,
              start_d,
              end_d
            )

          {:noreply,
           assign(socket,
             shift_coworkers_modal: %{
               rotation_type: type,
               start_date: start_d,
               end_date: end_d,
               coworker_rows: coworker_rows
             }
           )}
        else
          _ -> {:noreply, socket}
        end

      true ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("close_shift_coworkers", _params, socket) do
    {:noreply, assign(socket, shift_coworkers_modal: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-4xl mx-auto py-10 px-4">
      <div class="mb-4">
        <h1 class="text-2xl font-bold text-gray-800">
          {@resident.name}
          <span
            class="text-base font-normal text-gray-500"
            title={"Year #{@resident.residency_year}, resident #{@resident.schedule_number}"}
          >
            ({@resident.position_code})
          </span>
        </h1>
        <div class="flex items-center justify-between gap-2 mt-2">
          <div class="flex gap-2 flex-wrap">
            <%= for year <- @year_history do %>
              <%= if year.id == @resident.id do %>
                <span
                  class="px-3 py-1 rounded-full text-xs font-semibold bg-blue-600 text-white"
                  title="Currently viewing this year"
                >
                  {year.label}
                </span>
              <% else %>
                <.link
                  navigate={"/residents/#{year.id}"}
                  class="px-3 py-1 rounded-full text-xs font-semibold bg-gray-100 text-gray-600 hover:bg-gray-200 transition-colors"
                  title={"View #{@resident.name}'s #{year.label} schedule"}
                >
                  {year.label}
                </.link>
              <% end %>
            <% end %>
          </div>
          <%= if @is_home_resident do %>
            <div class="inline-flex items-center gap-1 shrink-0">
              <span class="inline-flex items-center gap-1 px-3 py-1 rounded-full text-xs font-semibold bg-green-100 text-green-700">
                ✓ Home
              </span>
              <form action="/unset-home" method="post" class="inline">
                <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
                <input type="hidden" name="resident_id" value={@resident.id} />
                <button
                  type="submit"
                  class="px-2 py-1 rounded-full text-xs text-gray-400 hover:bg-red-50 hover:text-red-500 transition-colors"
                  title="Remove Home — the nav link will no longer point here"
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
                title="Pin this resident — adds a Home shortcut to the nav"
              >
                Set as Home
              </button>
            </form>
          <% end %>
        </div>
      </div>

      <%= if @schedule_start && @schedule_end do %>
        <div class="mb-4 text-sm text-gray-500">
          {Calendar.strftime(@schedule_start, "%B %-d, %Y")} – {Calendar.strftime(
            @schedule_end,
            "%B %-d, %Y"
          )} &nbsp;·&nbsp;
          <a
            href={"/residents/#{@resident.id}/calendar.ics"}
            class="text-blue-600 hover:text-blue-800"
            title="One-time download — import into any calendar app"
          >
            Download .ics
          </a>
          <span class="text-gray-300 mx-1">·</span>
          <a
            href={"/feed/#{@resident.calendar_token}/calendar.ics"}
            class="text-blue-600 hover:text-blue-800"
            title="Subscribe — paste this URL into Google Calendar's 'Add from URL' to get live updates"
            onclick="navigator.clipboard.writeText(window.location.origin + this.getAttribute('href')); event.preventDefault(); this.textContent = 'Copied!'; setTimeout(() => this.textContent = 'Subscribe URL', 1500);"
          >
            Subscribe URL
          </a>
        </div>

        <%!-- Sticky stats container --%>
        <div id="sticky-stats" class="sticky top-14 z-40 bg-white mb-3">
          <%!-- Stats card: scrollable body, toggle button anchored at bottom outside scroll --%>
          <div class={[
            "border-2 border-gray-300",
            if(@stats_expanded && @night_shift_counts != [],
              do: "rounded-t-xl",
              else: "rounded-xl"
            )
          ]}>
            <%!-- Card header --%>
            <div class="flex items-center justify-between px-4 py-2 bg-gray-100 border-b-2 border-gray-300 rounded-t-xl">
              <span class="text-xs font-semibold text-gray-600">
                <span class="text-gray-800">{@resident.name}</span>
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
                  class={[
                    "w-3 h-3 transition-transform",
                    if(@stats_expanded, do: "rotate-90", else: "")
                  ]}
                  fill="currentColor"
                  viewBox="0 0 20 20"
                >
                  <path
                    fill-rule="evenodd"
                    d="M7.293 4.707a1 1 0 011.414 0l5 5a1 1 0 010 1.414l-5 5a1 1 0 01-1.414-1.414L11.586 10 7.293 5.707a1 1 0 010-1.414z"
                    clip-rule="evenodd"
                  />
                </svg>
                {if @stats_expanded, do: "Collapse", else: "Expand"}
              </button>
            </div>

            <%= if @stats_expanded do %>
              <%!-- Stats grid: scrollable, capped height --%>
              <div class="overflow-y-auto max-h-[25vh]">
                <div class="grid grid-cols-2 divide-x divide-y divide-gray-200 bg-gray-50">
                  <div class="px-4 py-3" title="Total scheduled service blocks (excludes vacation)">
                    <p class="text-xs font-medium text-gray-400 uppercase tracking-wide mb-0.5">
                      Total Shifts
                    </p>
                    <p class="text-xl font-bold text-gray-800">{@total_shifts}</p>
                  </div>
                  <div class="px-4 py-3" title="Service blocks with a start date on or after today">
                    <p class="text-xs font-medium text-gray-400 uppercase tracking-wide mb-0.5">
                      Shifts Remaining
                    </p>
                    <p class="text-xl font-bold text-gray-800">{@shifts_remaining}</p>
                  </div>
                  <div
                    class="px-4 py-3"
                    title="Night float and weekend night blocks at Strong Memorial remaining"
                  >
                    <p class="text-xs font-medium text-gray-400 uppercase tracking-wide mb-0.5">
                      Night Shifts Remaining – Strong
                    </p>
                    <p class="text-xl font-bold text-gray-800">{@night_shifts_remaining_strong}</p>
                  </div>
                  <div
                    class="px-4 py-3"
                    title="Night float and weekend night blocks at Highland remaining"
                  >
                    <p class="text-xs font-medium text-gray-400 uppercase tracking-wide mb-0.5">
                      Night Shifts Remaining – Highland
                    </p>
                    <p class="text-xl font-bold text-gray-800">{@night_shifts_remaining_highland}</p>
                  </div>
                </div>
              </div>

              <%!-- Night shift toggle: anchored at card bottom, never inside the scroll area --%>
              <%= if @night_shift_counts != [] do %>
                <div class={[
                  "border-t border-gray-200",
                  if(@stats_expanded && @night_shift_counts != [], do: "", else: "rounded-b-xl")
                ]}>
                  <button
                    phx-click="toggle_night_shifts"
                    class="flex items-center justify-between w-full px-4 py-2 text-xs font-medium text-gray-500 hover:bg-gray-100 hover:text-gray-700 transition-colors"
                  >
                    <span class="flex items-center gap-1.5">
                      <svg
                        class={[
                          "w-2.5 h-2.5 text-gray-400 transition-transform",
                          if(@night_shifts_expanded, do: "rotate-90", else: "")
                        ]}
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
                      {if @night_shifts_expanded, do: "Collapse", else: "Expand"}
                    </span>
                  </button>
                </div>
              <% end %>
            <% end %>
          </div>

          <%!-- Night shift breakdown drawer: expands below the card --%>
          <%= if @stats_expanded && @night_shifts_expanded && @night_shift_counts != [] do %>
            <div class="border-2 border-t-0 border-gray-300 rounded-b-xl overflow-hidden">
              <div class="divide-y divide-gray-100">
                <%= for {type, days} <- @night_shift_counts do %>
                  <% color = Rotations.rotation_type_color(type)
                  pill_label = Rotations.rotation_type_label(type) %>
                  <div class="flex items-center justify-between px-4 py-2 bg-white">
                    <span
                      title={pill_label}
                      class={[
                        "inline-flex h-8 w-44 max-w-full shrink-0 items-center justify-center truncate rounded px-2 text-xs font-medium",
                        color
                      ]}
                    >
                      {pill_label}
                    </span>
                    <span class="text-sm font-semibold text-gray-700">
                      {days} day{if days != 1, do: "s"}
                    </span>
                  </div>
                <% end %>
                <div class="flex items-center justify-between px-4 py-2 bg-gray-50">
                  <span class="text-sm font-medium text-gray-600">Total</span>
                  <span class="text-sm font-bold text-gray-800">
                    {@night_shift_counts |> Enum.map(&elem(&1, 1)) |> Enum.sum()} days
                  </span>
                </div>
              </div>
            </div>
          <% end %>
        </div>

        <div
          id="rotation-table"
          class="relative rounded-xl border-2 border-gray-300"
          phx-hook="ServiceFilterAnchored"
        >
          <div
            id="rotation-table-scroll"
            phx-hook="ScrollToToday"
            class="overflow-auto overscroll-contain rounded-xl [overflow-anchor:none]"
          >
            <table class="table-fixed w-full min-w-0 divide-y divide-gray-200 text-sm">
              <colgroup>
                <col style="width: 14rem" />
                <col />
                <col />
                <col style="width: 4.5rem" />
              </colgroup>
              <thead class="sticky top-0 z-10 bg-gray-100">
                <tr>
                  <th class="px-4 py-3 text-center font-semibold text-gray-600">
                    <div class="inline-flex items-center justify-center gap-0.5">
                      <span>Rotation</span>
                      <%= if @available_services != [] do %>
                        <button
                          id="service-filter-toggle"
                          type="button"
                          phx-click="toggle_service_filter_menu"
                          aria-haspopup="true"
                          aria-expanded={@service_filter_open}
                          aria-label={
                            if @service_filter_open,
                              do: "Close service filter menu",
                              else: "Open service filter menu"
                          }
                          class={[
                            "inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-md transition-colors duration-75 ease-out",
                            if(@service_filter_open,
                              do: "bg-gray-200 text-gray-800",
                              else: "text-gray-500 hover:bg-gray-200 hover:text-gray-800"
                            )
                          ]}
                        >
                          <.icon
                            name={
                              if @service_filter_open,
                                do: "hero-chevron-up",
                                else: "hero-chevron-down"
                            }
                            class="h-4 w-4"
                          />
                        </button>
                      <% end %>
                    </div>
                  </th>
                  <th class="px-4 py-3 text-center font-semibold text-gray-600">Start</th>
                  <th class="px-4 py-3 text-center font-semibold text-gray-600">End</th>
                  <th class="px-4 py-3 text-right font-semibold text-gray-600">Days</th>
                </tr>
              </thead>
              <tbody class="divide-y divide-gray-100">
                <%= if @filtered_entries == [] do %>
                  <tr id="rotation-table-empty-state">
                    <td colspan="4" class="px-4 py-8 text-center text-sm text-gray-400">
                      No schedule entries match the selected service filters.
                    </td>
                  </tr>
                <% else %>
                  <%= for entry <- @filtered_entries do %>
                    <% past = Date.compare(entry.end_date, @today) == :lt %>
                    <% covered = Map.get(entry, :covered_by) %>
                    <% is_coverage = Map.get(entry, :is_coverage, false) %>
                    <% color = entry_color(entry.rotation_type) %>
                    <% label = entry_label(entry.rotation_type) %>
                    <tr
                      id={
                      "rotation-entry-#{entry.rotation_type}-#{entry.slot_index}-#{Date.to_iso8601(entry.start_date)}-#{Date.to_iso8601(entry.end_date)}"
                    }
                      data-rotation-type={entry.rotation_type}
                      data-today-anchor={if entry.slot_index == @today_anchor_slot_index, do: "true"}
                      phx-click="open_shift_coworkers"
                      phx-value-rotation-type={entry.rotation_type}
                      phx-value-slot-index={entry.slot_index}
                      phx-value-start-date={Date.to_iso8601(entry.start_date)}
                      phx-value-end-date={Date.to_iso8601(entry.end_date)}
                      class={[
                        entry_row_class(entry.rotation_type, past),
                        if(covered, do: "opacity-60", else: ""),
                        "cursor-pointer"
                      ]}
                    >
                      <td class="px-4 py-2 align-top">
                        <div class="flex flex-col items-start gap-0.5 text-left">
                          <span
                            title={label}
                            class={[
                              "inline-flex h-8 w-full max-w-[11rem] shrink-0 items-center justify-center truncate rounded px-2 text-xs font-medium",
                              color,
                              if(covered, do: "line-through opacity-70", else: "")
                            ]}
                          >
                            {label}
                          </span>
                          <%= if covered do %>
                            <span class="max-w-full text-xs text-gray-400 italic break-words">
                              covered by {covered.name}
                            </span>
                          <% end %>
                          <%= if is_coverage do %>
                            <span class="max-w-full text-xs text-blue-500 italic break-words">
                              covering {entry.original_resident.name}
                            </span>
                          <% end %>
                        </div>
                      </td>
                      <td class={[
                        "px-4 py-2 text-center",
                        if(entry.rotation_type == "off", do: "text-gray-400", else: "text-gray-700")
                      ]}>
                        {Calendar.strftime(entry.start_date, "%b %-d, %Y")}
                      </td>
                      <td class={[
                        "px-4 py-2 text-center",
                        if(entry.rotation_type == "off", do: "text-gray-400", else: "text-gray-700")
                      ]}>
                        {Calendar.strftime(entry.end_date, "%b %-d, %Y")}
                      </td>
                      <td class={[
                        "px-4 py-2 text-right tabular-nums",
                        if(entry.rotation_type == "off", do: "text-gray-400", else: "text-gray-500")
                      ]}>
                        {Date.diff(entry.end_date, entry.start_date) + 1}
                      </td>
                    </tr>
                  <% end %>
                <% end %>
              </tbody>
            </table>
          </div>

          <%= if @available_services != [] && @service_filter_open do %>
            <div
              id="service-filter-panel"
              class={[
                "w-[min(22rem,calc(100vw-2rem))]",
                "rounded-2xl border border-gray-200/80 bg-white py-2 shadow-lg shadow-gray-900/10",
                "transition-[opacity,transform] duration-75 ease-out motion-reduce:transition-none",
                "opacity-100 scale-100"
              ]}
              role="menu"
              aria-label="Service filters"
            >
              <div class="flex items-start justify-between gap-3 border-b border-gray-100 px-3 pb-2">
                <div class="min-w-0">
                  <p class="text-sm font-semibold text-gray-900">Visible services</p>
                  <p class="text-xs text-gray-500">
                    {service_filter_count_label(@service_filters, @available_services)}
                  </p>
                </div>

                <button
                  id="service-filter-clear"
                  type="button"
                  phx-click="clear_service_filters"
                  role="menuitem"
                  class={[
                    "shrink-0 rounded-lg px-2.5 py-1 text-xs font-semibold transition-colors duration-75",
                    if(@service_filters == [],
                      do: "bg-blue-600 text-white hover:bg-blue-700",
                      else: "text-blue-600 hover:bg-blue-50"
                    )
                  ]}
                >
                  All
                </button>
              </div>

              <div
                id="service-filter-options"
                class="max-h-72 overflow-y-auto px-1 py-1"
                role="group"
                aria-label="Service options"
              >
                <%= for service <- @available_services do %>
                  <% selected = service.rotation_type in @service_filters %>
                  <button
                    id={"service-filter-option-#{service.rotation_type}"}
                    type="button"
                    phx-click="toggle_service_filter"
                    phx-value-service={service.rotation_type}
                    aria-pressed={selected}
                    role="menuitemcheckbox"
                    aria-checked={selected}
                    class={[
                      "flex w-full items-center justify-between gap-3 rounded-xl px-3 py-2.5 text-left text-sm",
                      "transition-colors duration-75 ease-out motion-reduce:transition-none",
                      if(selected,
                        do: "bg-blue-50/80 text-gray-900",
                        else: "text-gray-800 hover:bg-gray-50"
                      )
                    ]}
                  >
                    <span class="min-w-0 flex-1 font-medium">{service.label}</span>
                    <span class={[
                      "inline-flex h-5 w-5 shrink-0 items-center justify-center rounded border transition-colors duration-75",
                      if(selected,
                        do: "border-blue-600 bg-blue-600 text-white",
                        else: "border-gray-300 bg-white"
                      )
                    ]}>
                      <%= if selected do %>
                        <.icon name="hero-check" class="h-3.5 w-3.5" />
                      <% end %>
                    </span>
                  </button>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>

        <%= if @shift_coworkers_modal do %>
          <% modal = @shift_coworkers_modal %>
          <% type_label = entry_label(modal.rotation_type) %>
          <% color = entry_color(modal.rotation_type) %>
          <div
            id="shift-coworkers-modal"
            class="fixed inset-0 z-[70] flex items-center justify-center"
            role="dialog"
            aria-modal="true"
            aria-labelledby="shift-coworkers-modal-title"
          >
            <div phx-click="close_shift_coworkers" class="absolute inset-0 bg-black/40"></div>
            <div class="relative bg-white rounded-xl shadow-2xl p-6 max-w-md w-full mx-4 z-10 max-h-[80vh] overflow-y-auto">
              <div class="flex items-start justify-between gap-3 mb-4">
                <div>
                  <h3 id="shift-coworkers-modal-title" class="text-lg font-semibold text-gray-800">
                    {type_label}
                  </h3>
                  <p class="text-sm text-gray-500 mt-1">
                    {Calendar.strftime(modal.start_date, "%b %-d, %Y")} – {Calendar.strftime(
                      modal.end_date,
                      "%b %-d, %Y"
                    )}
                  </p>
                </div>
                <button
                  type="button"
                  phx-click="close_shift_coworkers"
                  class="text-gray-400 hover:text-gray-600 text-xl leading-none shrink-0"
                  aria-label="Close"
                >
                  ✕
                </button>
              </div>

              <div class="mb-3">
                <span class={"inline-block rounded px-2 py-0.5 text-xs font-medium #{color}"}>
                  {type_label}
                </span>
                <span class="text-xs text-gray-400 ml-2">
                  {length(modal.coworker_rows)} resident{if length(modal.coworker_rows) != 1, do: "s"}
                </span>
              </div>

              <%= if modal.coworker_rows == [] do %>
                <p class="text-sm text-gray-400">No schedule rows match this block.</p>
              <% else %>
                <ul id="shift-coworkers-list" class="space-y-3 pl-0.5">
                  <%= for row <- modal.coworker_rows do %>
                    <% sr = row.resident %>
                    <li class="flex flex-col gap-0.5 text-sm border-b border-gray-100 last:border-0 pb-3 last:pb-0">
                      <div class="flex items-center gap-2 flex-wrap">
                        <span class="text-xs text-gray-400 font-mono w-10 shrink-0">
                          {sr.position_code}
                        </span>
                        <.link
                          navigate={"/residents/#{sr.id}"}
                          class={[
                            "hover:text-blue-600 hover:underline font-medium",
                            if(row.overridden,
                              do: "line-through text-gray-400",
                              else: "text-gray-800"
                            )
                          ]}
                        >
                          {sr.name}
                        </.link>
                        <%= if row.overridden do %>
                          <span class="text-xs text-gray-400 italic">
                            → {row.covered_by.name}
                          </span>
                        <% end %>
                        <%= if row.is_coverage do %>
                          <span class="text-xs text-blue-500 italic">(covering)</span>
                        <% end %>
                      </div>
                      <p class="text-xs text-gray-500 pl-12">
                        {Rotations.format_date_set_within_block(
                          row.active_dates,
                          modal.start_date,
                          modal.end_date
                        )}
                      </p>
                    </li>
                  <% end %>
                </ul>
              <% end %>
            </div>
          </div>
        <% end %>
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
    do: [
      "bg-gray-50",
      "hover:bg-gray-100",
      "hover:shadow-sm",
      "hover:relative",
      "hover:z-20",
      "transition-colors"
    ]

  defp entry_row_class(_type, true), do: "opacity-40"

  defp entry_row_class(_type, false),
    do: [
      "hover:bg-gray-100",
      "hover:shadow-sm",
      "hover:relative",
      "hover:z-20",
      "transition-colors"
    ]

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

  defp merge_effective_entries(effective_segs, off_slots) do
    (effective_segs ++ off_slots)
    |> Enum.sort_by(& &1.start_date, Date)
  end

  defp build_service_options(entries) do
    entries
    |> Enum.reject(&(&1.rotation_type == "off"))
    |> Enum.map(& &1.rotation_type)
    |> Enum.uniq()
    |> Enum.sort_by(&String.downcase(entry_label(&1)))
    |> Enum.map(fn rotation_type ->
      %{rotation_type: rotation_type, label: entry_label(rotation_type)}
    end)
  end

  defp filter_entries(entries, []), do: entries

  defp filter_entries(entries, service_filters) do
    Enum.filter(entries, fn entry -> entry.rotation_type in service_filters end)
  end

  defp today_anchor_slot_index(entries, today) do
    case Enum.find(entries, fn entry -> Date.compare(entry.end_date, today) != :lt end) do
      nil -> nil
      entry -> entry.slot_index
    end
  end

  defp toggle_service(service_filters, service) do
    if service in service_filters do
      Enum.reject(service_filters, &(&1 == service))
    else
      service_filters ++ [service]
    end
  end

  defp normalize_service_filters(service_filters, available_services) do
    valid_services = MapSet.new(available_services, & &1.rotation_type)

    service_filters
    |> Enum.uniq()
    |> Enum.filter(&MapSet.member?(valid_services, &1))
  end

  defp assign_filtered_entries(socket, service_filters) do
    filtered_entries = filter_entries(socket.assigns.all_entries, service_filters)

    assign(socket,
      service_filters: service_filters,
      filtered_entries: filtered_entries,
      today_anchor_slot_index: today_anchor_slot_index(filtered_entries, socket.assigns.today),
      shift_coworkers_modal: nil
    )
  end

  defp service_filter_count_label([], available_services),
    do: "Showing all #{length(available_services)} services"

  defp service_filter_count_label(service_filters, _available_services) do
    count = length(service_filters)
    "Showing #{count} selected service#{if count == 1, do: "", else: "s"}"
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

  defp schedule_start_date(rotations),
    do: rotations |> Enum.map(& &1.start_date) |> Enum.min(Date)

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
