defmodule ResidencyScheduleWeb.ResidentLive.Show do
  use ResidencyScheduleWeb, :live_view

  alias ResidencySchedule.DetailedSchedules
  alias ResidencySchedule.ResidentDisplayNames
  alias ResidencySchedule.Residents
  alias ResidencySchedule.Rotations
  alias ResidencyScheduleWeb.ScheduleLive.Index, as: ScheduleIndex

  @strong_night_types ~w[night_float strong_weekend_nights]
  @highland_night_types ~w[highland_night_float highland_weekend_nights]
  @night_shift_types @strong_night_types ++ @highland_night_types
  @non_shift_types ~w[vacation leave_of_absence]

  @impl true
  def mount(%{"id" => id}, _session, socket) do
    current_user = socket.assigns.current_user
    home_resident_id = current_user && current_user.home_resident_id

    [resident] =
      [Residents.get_resident!(String.to_integer(id))]
      |> ResidentDisplayNames.apply_to_schedule_residents()

    today = ScheduleIndex.current_date()

    appearances = Residents.list_appearances_for_person(resident.resident_id)

    year_history =
      Enum.map(
        appearances,
        &%{id: &1.id, label: &1.schedule.label, academic_year: &1.schedule.academic_year}
      )

    # A resident is one entity that appears across academic years, so the table
    # spans their whole career and the stats are career-wide.
    {all_entries, all_rotations} = build_career_entries(appearances)

    schedule_start = schedule_start_date(all_rotations)
    schedule_end = schedule_end_date(all_rotations)
    night_shift_counts = count_night_shifts(all_rotations)
    available_services = build_service_options(all_entries)
    filtered_entries = filter_entries(all_entries, [])

    today_anchor_id = today_anchor_id(filtered_entries, today)

    total_shifts = compute_total_shifts(all_rotations)
    shifts_remaining = compute_shifts_remaining(all_rotations, today)

    night_shifts_remaining_strong =
      compute_night_shifts_remaining(all_rotations, today, @strong_night_types)

    night_shifts_remaining_highland =
      compute_night_shifts_remaining(all_rotations, today, @highland_night_types)

    {:ok,
     assign(socket,
       resident: resident,
       activity_date: today,
       day_activities: DetailedSchedules.list_for_resident(resident.id, today),
       day_base_rotations:
         Enum.filter(
           resident.rotations,
           &(Date.compare(&1.start_date, today) != :gt and Date.compare(&1.end_date, today) != :lt)
         ),
       year_history: year_history,
       multi_year?: length(year_history) > 1,
       is_home_resident: home_resident_id == resident.resident_id,
       schedule_start: schedule_start,
       schedule_end: schedule_end,
       night_shift_counts: night_shift_counts,
       all_entries: all_entries,
       filtered_entries: filtered_entries,
       available_services: available_services,
       service_filters: [],
       service_filter_open: false,
       today: today,
       today_anchor_id: today_anchor_id,
       total_shifts: total_shifts,
       shifts_remaining: shifts_remaining,
       night_shifts_remaining_strong: night_shifts_remaining_strong,
       night_shifts_remaining_highland: night_shifts_remaining_highland,
       stats_expanded: true,
       night_shifts_expanded: false,
       shift_coworkers_modal: nil,
       active_tab: :schedule,
       coworkers:
         resident.id
         |> Rotations.list_coworker_shared_shift_counts()
         |> ResidentDisplayNames.apply_to_entries(),
       current_user: current_user
     )}
  end

  @impl true
  def handle_event("resident-activity-date", %{"date" => date}, socket) do
    case Date.from_iso8601(date) do
      {:ok, selected} ->
        resident = socket.assigns.resident

        rotations =
          Enum.filter(
            resident.rotations,
            &(Date.compare(&1.start_date, selected) != :gt and
                Date.compare(&1.end_date, selected) != :lt)
          )

        {:noreply,
         assign(socket,
           activity_date: selected,
           day_activities: DetailedSchedules.list_for_resident(resident.id, selected),
           day_base_rotations: rotations
         )}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("tour_completed", _params, socket) do
    if socket.assigns.current_user do
      ResidencySchedule.Accounts.complete_tour(socket.assigns.current_user)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("switch_tab", %{"tab" => "coworkers"}, socket) do
    {:noreply, assign(socket, active_tab: :coworkers)}
  end

  @impl true
  def handle_event("switch_tab", _params, socket) do
    {:noreply, assign(socket, active_tab: :schedule)}
  end

  @impl true
  def handle_event("open_compare", %{"a" => a, "b" => b}, socket) do
    {:noreply, push_navigate(socket, to: "/compare?a=#{a}&b=#{b}")}
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

    # The row carries its own schedule (entries span multiple academic years),
    # so coworkers are looked up in that entry's schedule, not the page's.
    schedule_id = coworker_schedule_id(params, socket.assigns.resident.schedule_id)

    open_coworker_modal(type, sd, ed, schedule_id, socket)
  end

  @impl true
  def handle_event("close_shift_coworkers", _params, socket) do
    {:noreply, assign(socket, shift_coworkers_modal: nil)}
  end

  # Residents pin their own page ("Home"); user-role accounts follow someone
  # else's schedule (e.g. a resident's partner), so the copy differs by role.
  defp home_badge_label(%{role: :resident}), do: "Home"
  defp home_badge_label(_user), do: "Following"

  defp follow_button_label(%{role: :resident}), do: "Set as Home"
  defp follow_button_label(_user), do: "Follow"

  defp follow_button_title(%{role: :resident}),
    do: "Pin this resident — adds a Home shortcut to the nav"

  defp follow_button_title(_user),
    do: "Follow this resident — their schedule opens by default and appears in the nav"

  @impl true
  def render(assigns) do
    ~H"""
    <div
      id="guided-tour"
      phx-hook="GuidedTour"
      data-tour-page="resident"
      data-tour-role={to_string(@current_user.role)}
      class="max-w-4xl mx-auto py-10 px-4"
    >
      <div class="mb-4">
        <h1 class="text-2xl font-bold text-gray-800 dark:text-gray-100">
          {@resident.name}
          <span
            class="text-base font-normal text-gray-500 dark:text-gray-300"
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
                  class="px-3 py-1 rounded-full text-xs font-semibold bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 transition-colors"
                  title={"View #{@resident.name}'s #{year.label} schedule"}
                >
                  {year.label}
                </.link>
              <% end %>
            <% end %>
          </div>
          <%= if @is_home_resident do %>
            <div id="tour-follow-home" class="inline-flex items-center gap-1 shrink-0">
              <span class="inline-flex items-center gap-1 px-3 py-1 rounded-full text-xs font-semibold bg-green-100 dark:bg-green-900 text-green-700 dark:text-green-300">
                ✓ {home_badge_label(@current_user)}
              </span>
              <form action="/unset-home" method="post" class="inline">
                <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
                <input type="hidden" name="resident_id" value={@resident.id} />
                <button
                  type="submit"
                  class="px-2 py-1 rounded-full text-xs text-gray-400 dark:text-gray-400 hover:bg-red-50 dark:hover:bg-red-950 hover:text-red-500 dark:hover:text-red-300 transition-colors"
                  title="Remove — the nav link will no longer point here"
                >
                  ✕
                </button>
              </form>
            </div>
          <% else %>
            <form
              id="tour-follow-home"
              action={"/set-home/#{@resident.id}"}
              method="post"
              class="inline shrink-0"
            >
              <input type="hidden" name="_csrf_token" value={Plug.CSRFProtection.get_csrf_token()} />
              <button
                type="submit"
                class="px-3 py-1 rounded-full text-xs font-semibold bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-300 hover:bg-green-100 dark:hover:bg-green-900 hover:text-green-700 dark:hover:text-green-300 transition-colors"
                title={follow_button_title(@current_user)}
              >
                {follow_button_label(@current_user)}
              </button>
            </form>
          <% end %>
        </div>
      </div>

      <div class="mb-4 flex gap-1 border-b border-gray-200 dark:border-gray-700">
        <button
          phx-click="switch_tab"
          phx-value-tab="schedule"
          class={tab_button_class(@active_tab == :schedule)}
        >
          Schedule
        </button>
        <button
          phx-click="switch_tab"
          phx-value-tab="coworkers"
          class={tab_button_class(@active_tab == :coworkers)}
        >
          Coworkers
        </button>
      </div>

      <%= if @active_tab == :schedule do %>
        <section class="mb-6 rounded-xl border border-gray-200 dark:border-gray-700 p-4 space-y-3">
          <h2 class="font-semibold">Daily commitments</h2>
          <.form for={%{}} id="resident-activity-date-form" phx-change="resident-activity-date">
            <.input
              type="date"
              name="date"
              id="resident-activity-date"
              label="Show a date"
              value={Date.to_iso8601(@activity_date)}
            />
          </.form>
          <div id="resident-day-activities" class="space-y-3 text-sm">
            <p :for={rotation <- @day_base_rotations}>
              Base rotation: {Rotations.rotation_type_label(rotation.rotation_type)}
            </p>
            <p :if={@day_activities == []}>
              No QGenda detail for this date. Missing detail does not establish availability.
            </p>
            <article
              :for={activity <- @day_activities}
              class="rounded-md bg-gray-50 dark:bg-gray-900 p-3"
            >
              <p class="font-medium">{activity.display_name} — {activity.raw_task}</p>
              <p :if={activity.period || activity.site}>
                {activity.period || "Period unspecified"} · {activity.site || "Location unspecified"}
              </p>
              <p :for={note <- activity.notes}>{note}</p>
              <details class="mt-1 text-xs">
                <summary class="cursor-pointer">Source details</summary>
                <div :for={source <- activity.sources}>
                  <p>
                    {source.source_sheet}!{source.source_cell} · import {source.batch_id} · {source.raw_staff}
                  </p>
                  <p :for={note <- source.notes}>
                    {note.source_sheet}!{note.source_cell}: {note.text}
                  </p>
                </div>
              </details>
            </article>
          </div>
        </section>
        <%= if @schedule_start && @schedule_end do %>
          <div class="mb-4 text-sm text-gray-500 dark:text-gray-300">
            {Calendar.strftime(@schedule_start, "%B %-d, %Y")} – {Calendar.strftime(
              @schedule_end,
              "%B %-d, %Y"
            )} &nbsp;·&nbsp;
            <a
              href={"/residents/#{@resident.id}/calendar.ics"}
              class="text-blue-600 dark:text-blue-300 hover:text-blue-800 dark:hover:text-blue-300"
              title="One-time download — import into any calendar app"
            >
              Download .ics
            </a>
            <span class="text-gray-300 dark:text-gray-500 mx-1">·</span>
            <a
              href={"/feed/#{@resident.resident.calendar_token}/calendar.ics"}
              class="text-blue-600 dark:text-blue-300 hover:text-blue-800 dark:hover:text-blue-300"
              title="Subscribe — paste this URL into Google Calendar's 'Add from URL' to get live updates"
              onclick="navigator.clipboard.writeText(window.location.origin + this.getAttribute('href')); event.preventDefault(); this.textContent = 'Copied!'; setTimeout(() => this.textContent = 'Subscribe URL', 1500);"
            >
              Subscribe URL
            </a>
          </div>

          <%!-- Sticky stats container --%>
          <div id="sticky-stats" class="sticky top-14 z-40 bg-white dark:bg-gray-900 mb-3">
            <%!-- Stats card: scrollable body, toggle button anchored at bottom outside scroll --%>
            <div class={[
              "border-2 border-gray-300 dark:border-gray-600",
              if(@stats_expanded && @night_shift_counts != [],
                do: "rounded-t-xl",
                else: "rounded-xl"
              )
            ]}>
              <%!-- Card header --%>
              <div class="flex items-center justify-between px-4 py-2 bg-gray-100 dark:bg-gray-800 border-b-2 border-gray-300 dark:border-gray-600 rounded-t-xl">
                <span class="text-xs font-semibold text-gray-600 dark:text-gray-300">
                  <span class="text-gray-800 dark:text-gray-100">{@resident.name}</span>
                  <span class="text-gray-400 dark:text-gray-400 mx-1">·</span>
                  <span class="uppercase tracking-widest text-gray-500 dark:text-gray-300">
                    Schedule Stats
                  </span>
                </span>
                <button
                  phx-click="toggle_stats"
                  class={[
                    "flex items-center gap-1.5 text-xs font-medium rounded-full px-3 py-0.5 transition-colors",
                    if(@stats_expanded,
                      do:
                        "bg-gray-200 dark:bg-gray-700 text-gray-600 dark:text-gray-300 hover:bg-gray-300 dark:hover:bg-gray-600",
                      else:
                        "bg-blue-50 dark:bg-blue-950 text-blue-600 dark:text-blue-300 hover:bg-blue-100 dark:hover:bg-blue-900"
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
                  <div class="grid grid-cols-2 divide-x divide-y divide-gray-200 dark:divide-gray-700 bg-gray-50 dark:bg-gray-950">
                    <div class="px-4 py-3" title="Total scheduled service blocks (excludes vacation)">
                      <p class="text-xs font-medium text-gray-400 dark:text-gray-400 uppercase tracking-wide mb-0.5">
                        Total Shifts
                      </p>
                      <p class="text-xl font-bold text-gray-800 dark:text-gray-100">
                        {@total_shifts}
                      </p>
                    </div>
                    <div class="px-4 py-3" title="Service blocks with a start date on or after today">
                      <p class="text-xs font-medium text-gray-400 dark:text-gray-400 uppercase tracking-wide mb-0.5">
                        Shifts Remaining
                      </p>
                      <p class="text-xl font-bold text-gray-800 dark:text-gray-100">
                        {@shifts_remaining}
                      </p>
                    </div>
                    <div
                      class="px-4 py-3"
                      title="Night float and weekend night blocks at Strong Memorial remaining"
                    >
                      <p class="text-xs font-medium text-gray-400 dark:text-gray-400 uppercase tracking-wide mb-0.5">
                        Night Shifts Remaining – Strong
                      </p>
                      <p class="text-xl font-bold text-gray-800 dark:text-gray-100">
                        {@night_shifts_remaining_strong}
                      </p>
                    </div>
                    <div
                      class="px-4 py-3"
                      title="Night float and weekend night blocks at Highland remaining"
                    >
                      <p class="text-xs font-medium text-gray-400 dark:text-gray-400 uppercase tracking-wide mb-0.5">
                        Night Shifts Remaining – Highland
                      </p>
                      <p class="text-xl font-bold text-gray-800 dark:text-gray-100">
                        {@night_shifts_remaining_highland}
                      </p>
                    </div>
                  </div>
                </div>

                <%!-- Night shift toggle: anchored at card bottom, never inside the scroll area --%>
                <%= if @night_shift_counts != [] do %>
                  <div class={[
                    "border-t border-gray-200 dark:border-gray-700",
                    if(@stats_expanded && @night_shift_counts != [], do: "", else: "rounded-b-xl")
                  ]}>
                    <button
                      phx-click="toggle_night_shifts"
                      class="flex items-center justify-between w-full px-4 py-2 text-xs font-medium text-gray-500 dark:text-gray-300 hover:bg-gray-100 dark:hover:bg-gray-800 hover:text-gray-700 dark:hover:text-gray-200 transition-colors"
                    >
                      <span class="flex items-center gap-1.5">
                        <svg
                          class={[
                            "w-2.5 h-2.5 text-gray-400 dark:text-gray-400 transition-transform",
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
                          do: "bg-gray-200 dark:bg-gray-700 text-gray-600 dark:text-gray-300",
                          else: "bg-gray-100 dark:bg-gray-800 text-gray-500 dark:text-gray-300"
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
              <div class="border-2 border-t-0 border-gray-300 dark:border-gray-600 rounded-b-xl overflow-hidden">
                <div class="divide-y divide-gray-100 dark:divide-gray-700">
                  <%= for {type, days} <- @night_shift_counts do %>
                    <% color = Rotations.rotation_type_color(type)
                    pill_label = Rotations.rotation_type_label(type) %>
                    <div class="flex items-center justify-between px-4 py-2 bg-white dark:bg-gray-900">
                      <span
                        title={pill_label}
                        class={[
                          "inline-flex h-8 w-44 max-w-full shrink-0 items-center justify-center truncate rounded px-2 text-xs font-medium",
                          color
                        ]}
                      >
                        {pill_label}
                      </span>
                      <span class="text-sm font-semibold text-gray-700 dark:text-gray-200">
                        {days} day{if days != 1, do: "s"}
                      </span>
                    </div>
                  <% end %>
                  <div class="flex items-center justify-between px-4 py-2 bg-gray-50 dark:bg-gray-950">
                    <span class="text-sm font-medium text-gray-600 dark:text-gray-300">Total</span>
                    <span class="text-sm font-bold text-gray-800 dark:text-gray-100">
                      {@night_shift_counts |> Enum.map(&elem(&1, 1)) |> Enum.sum()} days
                    </span>
                  </div>
                </div>
              </div>
            <% end %>
          </div>

          <div
            id="rotation-table"
            class="relative rounded-xl border-2 border-gray-300 dark:border-gray-600"
            phx-hook="ServiceFilterAnchored"
          >
            <div
              id="rotation-table-scroll"
              phx-hook="ScrollToToday"
              class="overflow-auto overscroll-contain rounded-xl [overflow-anchor:none]"
            >
              <table class="table-fixed w-full min-w-0 divide-y divide-gray-200 dark:divide-gray-700 text-sm">
                <colgroup>
                  <col style="width: 14rem" />
                  <col />
                  <col />
                  <col style="width: 4.5rem" />
                </colgroup>
                <thead class="sticky top-0 z-10 bg-gray-100 dark:bg-gray-800">
                  <tr>
                    <th class="px-4 py-3 text-center font-semibold text-gray-600 dark:text-gray-300">
                      <div class="inline-flex items-center justify-center gap-0.5">
                        <span>Rotation</span>
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
                              do: "bg-gray-200 dark:bg-gray-700 text-gray-800 dark:text-gray-100",
                              else:
                                "text-gray-500 dark:text-gray-300 hover:bg-gray-200 dark:hover:bg-gray-700 hover:text-gray-800 dark:hover:text-gray-100"
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
                      </div>
                    </th>
                    <th class="px-4 py-3 text-center font-semibold text-gray-600 dark:text-gray-300">
                      Start
                    </th>
                    <th class="px-4 py-3 text-center font-semibold text-gray-600 dark:text-gray-300">
                      End
                    </th>
                    <th class="px-4 py-3 text-right font-semibold text-gray-600 dark:text-gray-300">
                      Days
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-100 dark:divide-gray-700">
                  <%= if @filtered_entries == [] do %>
                    <tr id="rotation-table-empty-state">
                      <td
                        colspan="4"
                        class="px-4 py-8 text-center text-sm text-gray-400 dark:text-gray-400"
                      >
                        No schedule entries match the selected service filters.
                      </td>
                    </tr>
                  <% else %>
                    <%= for {year_label, year_entries} <- chunk_by_year(@filtered_entries) do %>
                      <%= if @multi_year? do %>
                        <tr class="bg-gray-50 dark:bg-gray-950">
                          <td
                            colspan="4"
                            class="px-4 py-1.5 text-xs font-semibold uppercase tracking-widest text-gray-500 dark:text-gray-300"
                          >
                            {year_label}
                          </td>
                        </tr>
                      <% end %>
                      <%= for entry <- year_entries do %>
                        <% past = Date.compare(entry.end_date, @today) == :lt %>
                        <% covered = Map.get(entry, :covered_by) %>
                        <% is_coverage = Map.get(entry, :is_coverage, false) %>
                        <% color = entry_color(entry.rotation_type) %>
                        <% label = entry_label(entry.rotation_type) %>
                        <tr
                          id={entry_row_id(entry)}
                          data-rotation-type={entry.rotation_type}
                          data-today-anchor={if entry_row_id(entry) == @today_anchor_id, do: "true"}
                          phx-click="open_shift_coworkers"
                          phx-value-rotation-type={entry.rotation_type}
                          phx-value-slot-index={entry.slot_index}
                          phx-value-schedule-id={entry.schedule_id}
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
                                <span class="max-w-full text-xs text-gray-400 dark:text-gray-400 italic break-words">
                                  covered by {covered.name}
                                </span>
                              <% end %>
                              <%= if is_coverage do %>
                                <span class="max-w-full text-xs text-blue-500 dark:text-blue-300 italic break-words">
                                  covering {entry.original_resident.name}
                                </span>
                              <% end %>
                            </div>
                          </td>
                          <td class={[
                            "px-4 py-2 text-center",
                            if(entry.rotation_type == "off",
                              do: "text-gray-400 dark:text-gray-400",
                              else: "text-gray-700 dark:text-gray-200"
                            )
                          ]}>
                            {Calendar.strftime(entry.start_date, "%b %-d, %Y")}
                          </td>
                          <td class={[
                            "px-4 py-2 text-center",
                            if(entry.rotation_type == "off",
                              do: "text-gray-400 dark:text-gray-400",
                              else: "text-gray-700 dark:text-gray-200"
                            )
                          ]}>
                            {Calendar.strftime(entry.end_date, "%b %-d, %Y")}
                          </td>
                          <td class={[
                            "px-4 py-2 text-right tabular-nums",
                            if(entry.rotation_type == "off",
                              do: "text-gray-400 dark:text-gray-400",
                              else: "text-gray-500 dark:text-gray-300"
                            )
                          ]}>
                            {Date.diff(entry.end_date, entry.start_date) + 1}
                          </td>
                        </tr>
                      <% end %>
                    <% end %>
                  <% end %>
                </tbody>
              </table>
            </div>

            <%!-- Desktop dropdown --%>
            <%= if @service_filter_open do %>
              <div
                id="service-filter-panel"
                class={[
                  "hidden sm:block",
                  "w-[min(22rem,calc(100vw-2rem))]",
                  "rounded-2xl border border-gray-200/80 dark:border-gray-700/80 bg-white dark:bg-gray-900 py-2 shadow-lg shadow-gray-900/10",
                  "transition-[opacity,transform] duration-75 ease-out motion-reduce:transition-none",
                  "opacity-100 scale-100"
                ]}
                role="menu"
                aria-label="Service filters"
              >
                {service_filter_body(assigns)}
              </div>

              <%!-- Mobile bottom sheet --%>
              <div class="sm:hidden fixed inset-0 z-[70] flex items-end justify-center">
                <div phx-click="close_service_filter_menu" class="absolute inset-0 bg-black/40"></div>
                <div
                  class="relative w-full bg-white dark:bg-gray-900 rounded-t-2xl shadow-lg py-2 max-h-[70vh] flex flex-col"
                  role="menu"
                  aria-label="Service filters"
                >
                  {service_filter_body(assigns)}
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
              <div class="relative bg-white dark:bg-gray-900 rounded-xl shadow-2xl p-6 max-w-md w-full mx-4 z-10 max-h-[80vh] overflow-y-auto">
                <div class="flex items-start justify-between gap-3 mb-4">
                  <div>
                    <h3
                      id="shift-coworkers-modal-title"
                      class="text-lg font-semibold text-gray-800 dark:text-gray-100"
                    >
                      {type_label}
                    </h3>
                    <p class="text-sm text-gray-500 dark:text-gray-300 mt-1">
                      {Calendar.strftime(modal.start_date, "%b %-d, %Y")} – {Calendar.strftime(
                        modal.end_date,
                        "%b %-d, %Y"
                      )}
                    </p>
                  </div>
                  <button
                    type="button"
                    phx-click="close_shift_coworkers"
                    class="text-gray-400 dark:text-gray-400 hover:text-gray-600 dark:hover:text-gray-300 text-xl leading-none shrink-0"
                    aria-label="Close"
                  >
                    ✕
                  </button>
                </div>

                <div class="mb-3">
                  <span class={"inline-block rounded px-2 py-0.5 text-xs font-medium #{color}"}>
                    {type_label}
                  </span>
                  <span class="text-xs text-gray-400 dark:text-gray-400 ml-2">
                    {length(modal.coworker_rows)} resident{if length(modal.coworker_rows) != 1,
                      do: "s"}
                  </span>
                </div>

                <%= if modal.coworker_rows == [] do %>
                  <p class="text-sm text-gray-400 dark:text-gray-400">
                    No schedule rows match this block.
                  </p>
                <% else %>
                  <ul id="shift-coworkers-list" class="space-y-3 pl-0.5">
                    <%= for row <- modal.coworker_rows do %>
                      <% sr = row.resident %>
                      <li class="flex flex-col gap-0.5 text-sm border-b border-gray-100 dark:border-gray-700 last:border-0 pb-3 last:pb-0">
                        <div class="flex items-center gap-2 flex-wrap">
                          <span class="text-xs text-gray-400 dark:text-gray-400 font-mono w-10 shrink-0">
                            {sr.position_code}
                          </span>
                          <.link
                            navigate={"/residents/#{sr.id}"}
                            class={[
                              "hover:text-blue-600 dark:hover:text-blue-300 hover:underline font-medium",
                              if(row.overridden,
                                do: "line-through text-gray-400 dark:text-gray-400",
                                else: "text-gray-800 dark:text-gray-100"
                              )
                            ]}
                          >
                            {sr.name}
                          </.link>
                          <%= if row.overridden do %>
                            <span class="text-xs text-gray-400 dark:text-gray-400 italic">
                              → {row.covered_by.name}
                            </span>
                          <% end %>
                          <%= if row.is_coverage do %>
                            <span class="text-xs text-blue-500 dark:text-blue-300 italic">
                              (covering)
                            </span>
                          <% end %>
                        </div>
                        <p class="text-xs text-gray-500 dark:text-gray-300 pl-12">
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
          <p class="text-gray-500 dark:text-gray-300">No rotations recorded for this resident.</p>
        <% end %>
      <% end %>

      <%= if @active_tab == :coworkers do %>
        <div id="coworkers-tab">
          <%= if @coworkers == [] do %>
            <p class="text-gray-500 dark:text-gray-300 py-8 text-center">
              No shared shifts with any other resident this year.
            </p>
          <% else %>
            <p class="mb-3 text-sm text-gray-500 dark:text-gray-300">
              Residents {@resident.name} shares shifts with, most to least. Select a row to compare
              their schedules side by side.
            </p>
            <div class="rounded-xl border-2 border-gray-300 dark:border-gray-600 overflow-hidden">
              <table class="min-w-full divide-y divide-gray-200 dark:divide-gray-700 text-sm">
                <thead class="bg-gray-100 dark:bg-gray-800">
                  <tr>
                    <th class="px-4 py-3 text-left font-semibold text-gray-600 dark:text-gray-300">
                      Resident
                    </th>
                    <th class="px-4 py-3 text-right font-semibold text-gray-600 dark:text-gray-300">
                      Shared Shifts
                    </th>
                  </tr>
                </thead>
                <tbody class="divide-y divide-gray-100 dark:divide-gray-700">
                  <%= for coworker <- @coworkers do %>
                    <tr
                      id={"coworker-row-#{coworker.resident.id}"}
                      phx-click="open_compare"
                      phx-value-a={@resident.id}
                      phx-value-b={coworker.resident.id}
                      class="cursor-pointer hover:bg-gray-100 dark:hover:bg-gray-800 hover:shadow-sm transition-colors"
                    >
                      <td class="px-4 py-3">
                        <div class="flex items-center gap-2">
                          <span class="text-xs text-gray-400 dark:text-gray-400 font-mono w-10 shrink-0">
                            {coworker.resident.position_code}
                          </span>
                          <span class="font-medium text-gray-800 dark:text-gray-100">
                            {coworker.resident.name}
                          </span>
                        </div>
                      </td>
                      <td class="px-4 py-3 text-right tabular-nums font-semibold text-gray-700 dark:text-gray-200">
                        {coworker.shared_shifts}
                      </td>
                    </tr>
                  <% end %>
                </tbody>
              </table>
            </div>
          <% end %>
        </div>
      <% end %>
    </div>
    """
  end

  defp tab_button_class(active?) do
    [
      "px-4 py-2 text-sm font-medium -mb-px border-b-2 transition-colors",
      if(active?,
        do: "border-blue-600 text-blue-600 dark:text-blue-300",
        else:
          "border-transparent text-gray-500 dark:text-gray-300 hover:text-gray-700 dark:hover:text-gray-200 hover:border-gray-300 dark:hover:border-gray-600"
      )
    ]
  end

  # --- Private helpers ---

  defp entry_color("off"), do: "bg-gray-100 dark:bg-gray-800 text-gray-400 dark:text-gray-400"
  defp entry_color(rotation_type), do: Rotations.rotation_type_color(rotation_type)

  defp entry_label("off"), do: "OFF"
  defp entry_label(rotation_type), do: Rotations.rotation_type_label(rotation_type)

  defp entry_row_class("off", true), do: ["opacity-40", "bg-gray-50 dark:bg-gray-950"]

  defp entry_row_class("off", false),
    do: [
      "bg-gray-50 dark:bg-gray-950",
      "hover:bg-gray-100 dark:hover:bg-gray-800",
      "hover:shadow-sm",
      "hover:relative",
      "hover:z-20",
      "transition-colors"
    ]

  defp entry_row_class(_type, true), do: "opacity-40"

  defp entry_row_class(_type, false),
    do: [
      "hover:bg-gray-100 dark:hover:bg-gray-800",
      "hover:shadow-sm",
      "hover:relative",
      "hover:z-20",
      "transition-colors"
    ]

  defp compute_off_slots(rotations, schedule_slots) do
    schedule_slots
    |> Enum.reject(fn {_index, start, _finish} ->
      Enum.any?(
        rotations,
        &(Date.compare(&1.start_date, start) != :gt and Date.compare(&1.end_date, start) != :lt)
      )
    end)
    |> Enum.map(fn {index, start, finish} ->
      %{slot_index: index, start_date: start, end_date: finish, rotation_type: "off"}
    end)
  end

  defp merge_effective_entries(effective_segs, off_slots) do
    (effective_segs ++ off_slots)
    |> Enum.sort_by(& &1.start_date, Date)
  end

  # Builds the resident's full multi-year timeline. Returns the rotation/off
  # entries from every academic year (tagged with the year and schedule for
  # section headers and coworker lookups), sorted chronologically, plus the flat
  # list of all their rotations for career-wide stats.
  defp build_career_entries(appearances) do
    per_year = Enum.map(appearances, &year_entries/1)

    all_entries =
      per_year
      |> Enum.flat_map(& &1.entries)
      |> ResidentDisplayNames.apply_to_entries()
      |> Enum.sort_by(& &1.start_date, Date)

    all_rotations = Enum.flat_map(per_year, & &1.rotations)

    {all_entries, all_rotations}
  end

  defp year_entries(schedule_resident) do
    rotations = Rotations.list_rotations_for_resident(schedule_resident.id)

    off_slots =
      compute_off_slots(
        rotations,
        Rotations.list_schedule_date_slots(schedule_resident.schedule_id)
      )

    entries =
      schedule_resident.id
      |> Rotations.effective_segments_for_resident()
      |> merge_effective_entries(off_slots)
      |> Enum.map(&tag_entry_with_schedule(&1, schedule_resident))

    %{entries: entries, rotations: rotations}
  end

  defp tag_entry_with_schedule(entry, schedule_resident) do
    entry
    |> Map.put(:schedule_id, schedule_resident.schedule_id)
    |> Map.put(:academic_year, schedule_resident.schedule.academic_year)
    |> Map.put(:schedule_label, schedule_resident.schedule.label)
  end

  # Groups chronologically-sorted entries into `{schedule_label, entries}` per
  # academic year (years never overlap, so same-year entries are contiguous).
  defp chunk_by_year(entries) do
    entries
    |> Enum.chunk_by(& &1.academic_year)
    |> Enum.map(fn [first | _] = chunk -> {first.schedule_label, chunk} end)
  end

  defp coworker_schedule_id(params, fallback) do
    case Integer.parse(params["schedule-id"] || params["schedule_id"] || "") do
      {schedule_id, ""} -> schedule_id
      _ -> fallback
    end
  end

  defp build_service_options(entries) do
    rotation_types =
      entries
      |> Enum.map(& &1.rotation_type)
      |> Enum.reject(&(&1 == "off"))
      |> Enum.uniq()

    ["off" | rotation_types]
    |> Enum.sort_by(&String.downcase(entry_label(&1)))
    |> Enum.map(fn rotation_type ->
      %{rotation_type: rotation_type, label: entry_label(rotation_type)}
    end)
  end

  defp filter_entries(entries, []), do: entries

  defp filter_entries(entries, service_filters) do
    Enum.filter(entries, fn entry -> entry.rotation_type in service_filters end)
  end

  @doc """
  Returns the DOM id of the row to scroll to on mount.

  Picks the first entry whose end_date is on or after today (i.e. the current
  or next upcoming rotation). When today is past every entry in the list,
  falls back to the first entry so the table starts at the beginning rather
  than an arbitrary scroll position. The id is unique across the resident's
  whole multi-year timeline (it includes the entry's dates).

      iex> entries = [
      ...>   %{rotation_type: "oncology", slot_index: 0, start_date: ~D[2024-07-01], end_date: ~D[2024-07-15]},
      ...>   %{rotation_type: "elective", slot_index: 1, start_date: ~D[2024-08-01], end_date: ~D[2024-08-15]}
      ...> ]
      iex> ResidencyScheduleWeb.ResidentLive.Show.today_anchor_id(entries, ~D[2024-07-20])
      "rotation-entry-elective-1-2024-08-01-2024-08-15"
  """
  def today_anchor_id([], _today), do: nil

  def today_anchor_id(entries, today) do
    entry =
      Enum.find(entries, fn entry -> Date.compare(entry.end_date, today) != :lt end) ||
        hd(entries)

    entry_row_id(entry)
  end

  @doc """
  Builds the stable, timeline-unique DOM id for a rotation/off entry row.

      iex> entry = %{rotation_type: "oncology", slot_index: 2, start_date: ~D[2024-07-01], end_date: ~D[2024-07-15]}
      iex> ResidencyScheduleWeb.ResidentLive.Show.entry_row_id(entry)
      "rotation-entry-oncology-2-2024-07-01-2024-07-15"
  """
  def entry_row_id(entry) do
    "rotation-entry-#{entry.rotation_type}-#{entry.slot_index}-#{Date.to_iso8601(entry.start_date)}-#{Date.to_iso8601(entry.end_date)}"
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
      today_anchor_id: today_anchor_id(filtered_entries, socket.assigns.today),
      shift_coworkers_modal: nil
    )
  end

  defp service_filter_body(assigns) do
    ~H"""
    <div class="flex items-start justify-between gap-3 border-b border-gray-100 dark:border-gray-700 px-3 pb-2">
      <div class="min-w-0">
        <p class="text-sm font-semibold text-gray-900 dark:text-gray-100">Visible services</p>
        <p class="text-xs text-gray-500 dark:text-gray-300">
          {service_filter_count_label(@service_filters, @available_services)}
        </p>
      </div>

      <button
        type="button"
        phx-click="clear_service_filters"
        role="menuitem"
        class={[
          "shrink-0 rounded-lg px-2.5 py-1 text-xs font-semibold transition-colors duration-75",
          if(@service_filters == [],
            do: "bg-blue-600 text-white hover:bg-blue-700",
            else: "text-blue-600 dark:text-blue-300 hover:bg-blue-50 dark:hover:bg-blue-950"
          )
        ]}
      >
        All
      </button>
    </div>

    <div
      class="max-h-72 overflow-y-auto px-1 py-1"
      role="group"
      aria-label="Service options"
    >
      <%= for service <- @available_services do %>
        <% selected = service.rotation_type in @service_filters %>
        <button
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
              do: "bg-blue-50/80 dark:bg-blue-950/80 text-gray-900 dark:text-gray-100",
              else: "text-gray-800 dark:text-gray-100 hover:bg-gray-50 dark:hover:bg-gray-950"
            )
          ]}
        >
          <span class="min-w-0 flex-1 font-medium">{service.label}</span>
          <span class={[
            "inline-flex h-5 w-5 shrink-0 items-center justify-center rounded border transition-colors duration-75",
            if(selected,
              do: "border-blue-600 bg-blue-600 text-white",
              else: "border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900"
            )
          ]}>
            <%= if selected do %>
              <.icon name="hero-check" class="h-3.5 w-3.5" />
            <% end %>
          </span>
        </button>
      <% end %>
    </div>
    """
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
    |> Enum.reject(fn r ->
      r.rotation_type in @non_shift_types or Date.compare(r.end_date, today) == :lt
    end)
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

  defp open_coworker_modal(type, sd, ed, schedule_id, socket) do
    cond do
      type == "off" and is_binary(sd) and is_binary(ed) ->
        with {:ok, start_d} <- Date.from_iso8601(sd),
             {:ok, end_d} <- Date.from_iso8601(ed) do
          coworker_rows =
            Rotations.list_off_coworker_rows_in_range(schedule_id, start_d, end_d)
            |> ResidentDisplayNames.apply_to_entries()

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
              schedule_id,
              type,
              start_d,
              end_d
            )
            |> ResidentDisplayNames.apply_to_entries()

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
end
