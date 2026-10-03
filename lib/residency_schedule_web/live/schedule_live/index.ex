defmodule ResidencyScheduleWeb.ScheduleLive.Index do
  use ResidencyScheduleWeb, :live_view

  alias ResidencySchedule.Accounts
  alias ResidencySchedule.DetailedSchedules
  alias ResidencySchedule.ResidentDisplayNames
  alias ResidencySchedule.Residents
  alias ResidencySchedule.Rotations
  alias ResidencySchedule.Schedules
  alias ResidencyScheduleWeb.DailyAssignments

  # Fixed pixel width for the sticky name column — must match left-[Xpx] values below.
  @name_col_px 148

  @impl true
  def mount(_params, _session, socket) do
    schedules = Schedules.list_schedules()
    today = current_date()

    socket =
      if schedules != [] do
        load_all_schedules(socket, schedules, today)
      else
        assign(socket,
          schedules: [],
          all_slots: [],
          unified_residents: [],
          filter_year: nil
        )
      end

    {:ok,
     assign(socket,
       delete_confirm_id: nil,
       delete_error: nil,
       rotation_modal: nil,
       demo_mode: ResidencySchedule.demo_mode?(),
       is_admin: Accounts.User.admin?(socket.assigns.current_user),
       today: today,
       viewed_aca_year: current_academic_year(today)
     )}
  end

  @impl true
  def handle_params(_params, _uri, socket), do: {:noreply, socket}

  @impl true
  def handle_event("scroll_to_schedule", %{"id" => id}, socket) do
    {:noreply,
     socket |> assign(rotation_modal: nil) |> push_event("scroll-to-schedule", %{schedule_id: id})}
  end

  @impl true
  def handle_event("open_rotation_details", params, socket) do
    modal = find_rotation_details(socket.assigns, Map.get(params, "cell-id"))
    {:noreply, assign(socket, rotation_modal: modal)}
  end

  @impl true
  def handle_event("close_rotation_details", _params, socket) do
    {:noreply, assign(socket, rotation_modal: nil)}
  end

  @impl true
  def handle_event("tour_completed", _params, socket) do
    if socket.assigns.current_user do
      Accounts.complete_tour(socket.assigns.current_user)
    end

    {:noreply, socket}
  end

  @impl true
  def handle_event("restart_tour", _params, socket) do
    {:noreply, push_event(socket, "start-tour", %{})}
  end

  @impl true
  def handle_event("filter_year", %{"year" => year}, socket) do
    filter_year = if year == "all", do: nil, else: String.to_integer(year)
    {:noreply, assign(socket, filter_year: filter_year, rotation_modal: nil)}
  end

  @impl true
  def handle_event("view_academic_year", %{"aca_year" => aca_year}, socket) do
    {:noreply, assign(socket, viewed_aca_year: to_integer(aca_year), rotation_modal: nil)}
  end

  @impl true
  def handle_event("request_delete", _params, %{assigns: %{demo_mode: true}} = socket) do
    {:noreply, socket}
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
  def handle_event("delete_schedule", _params, %{assigns: %{demo_mode: true}} = socket) do
    {:noreply, assign(socket, delete_error: "Deleting is disabled in the demo.")}
  end

  @impl true
  def handle_event("delete_schedule", %{"schedule_id" => id, "password" => password}, socket) do
    if authorized_to_delete?(socket.assigns.current_user, password) do
      case Schedules.delete_schedule(String.to_integer(id)) do
        {:ok, _} ->
          {:noreply, refresh_after_delete(socket)}

        {:error, reason} ->
          {:noreply,
           assign(socket,
             delete_error:
               if(is_binary(reason), do: reason, else: "This schedule could not be deleted.")
           )}
      end
    else
      {:noreply, assign(socket, delete_error: delete_error_message(socket.assigns.current_user))}
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :name_col_px, @name_col_px)

    ~H"""
    <div
      id="guided-tour"
      phx-hook="GuidedTour"
      data-tour-page="schedule"
      data-tour-role={to_string(@current_user.role)}
      class="min-h-screen bg-gray-50 dark:bg-gray-950"
    >
      <%= if @schedules != [] do %>
        <div
          id="tour-schedule-pills"
          class="bg-white dark:bg-gray-900 border-b border-gray-200 dark:border-gray-700 px-4 sm:px-6 py-2 flex items-center gap-3 flex-wrap"
        >
          <span class="text-sm text-gray-500 dark:text-gray-300">Schedule:</span>
          <%= for s <- @schedules do %>
            <div class="flex items-center gap-0.5">
              <button
                phx-click="scroll_to_schedule"
                phx-value-id={s.id}
                class={[
                  "px-3 py-1 text-sm font-medium transition-colors",
                  if(@is_admin, do: "rounded-l-full", else: "rounded-full"),
                  "bg-gray-100 dark:bg-gray-800 text-gray-700 dark:text-gray-200 hover:bg-gray-200 dark:hover:bg-gray-700"
                ]}
                data-schedule-pill={s.id}
              >
                {s.label}
              </button>
              <%= if @is_admin do %>
                <button
                  phx-click="request_delete"
                  phx-value-id={s.id}
                  class="px-1.5 py-1 rounded-r-full text-sm font-medium transition-colors bg-gray-200 dark:bg-gray-700 text-gray-500 dark:text-gray-300 hover:bg-red-100 dark:hover:bg-red-900 hover:text-red-700 dark:hover:text-red-300"
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
              class="flex items-center gap-2 ml-2 pl-3 border-l border-gray-200 dark:border-gray-700"
            >
              <input type="hidden" name="schedule_id" value={@delete_confirm_id} />
              <span class="text-sm text-red-700 dark:text-red-300 font-medium">
                Delete {target && target.label}?
              </span>
              <input
                type="password"
                name="password"
                placeholder="Password"
                autofocus
                class="border border-gray-300 dark:border-gray-600 rounded px-2 py-0.5 text-sm w-32 focus:outline-none focus:ring-1 focus:ring-red-400"
              />
              <%= if @delete_error do %>
                <span id="schedule-delete-error" class="text-xs text-red-600 dark:text-red-300">
                  {@delete_error}
                </span>
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
                class="px-3 py-0.5 bg-gray-100 dark:bg-gray-800 text-gray-700 dark:text-gray-200 rounded text-sm font-medium hover:bg-gray-200 dark:hover:bg-gray-700 transition-colors"
              >
                Cancel
              </button>
            </form>
          <% end %>
        </div>
      <% end %>

      <%= if @all_slots != [] do %>
        <div class="px-4 sm:px-6 py-4 flex flex-wrap items-center gap-4 border-b border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900">
          <div id="tour-year-filter" class="flex flex-wrap items-center gap-2">
            <span class="text-sm text-gray-500 dark:text-gray-300 font-medium">Year:</span>
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

          <div class="ml-auto flex items-center gap-3">
            <button
              phx-click="restart_tour"
              class="text-sm text-blue-500 dark:text-blue-300 hover:text-blue-700 dark:hover:text-blue-300 transition-colors"
              title="Take a guided tour"
            >
              Take a tour
            </button>
            <span
              id="gantt-year-indicator"
              class="text-sm font-semibold text-gray-500 dark:text-gray-300 tabular-nums"
            >
            </span>
          </div>
        </div>

        <div id="gantt-scroll" phx-hook="YearTracker" class="overflow-x-auto">
          <table class="border-separate border-spacing-0 text-xs">
            <thead>
              <tr class="bg-gray-100 dark:bg-gray-800 sticky top-0 z-30">
                <th
                  class="sticky left-0 z-40 bg-gray-100 dark:bg-gray-800 px-2 py-2 text-left font-semibold text-gray-600 dark:text-gray-300 border-b border-r border-gray-300 dark:border-gray-600 whitespace-nowrap overflow-hidden"
                  style={"width: #{@name_col_px}px; min-width: #{@name_col_px}px; max-width: #{@name_col_px}px"}
                >
                  Name
                </th>
                <%= for {schedule_id, _idx, start_date, end_date, first_in_schedule?} <- @all_slots do %>
                  <% slot_past = Date.compare(end_date, @today) == :lt %>
                  <% slot_today = not slot_past and Date.compare(start_date, @today) != :gt %>
                  <th
                    class={[
                      "px-1 py-2 text-center font-medium border-b border-gray-200 dark:border-gray-700 whitespace-nowrap",
                      if(slot_past,
                        do: "text-gray-300 dark:text-gray-500",
                        else: "text-gray-500 dark:text-gray-300"
                      ),
                      if(first_in_schedule? and schedule_id != elem(hd(@all_slots), 0),
                        do: "border-l-2 border-l-blue-300 dark:border-l-blue-800",
                        else: ""
                      )
                    ]}
                    style="min-width: 52px"
                    data-slot-year={start_date.year}
                    data-slot-aca-year={
                      if start_date.month >= 7, do: start_date.year, else: start_date.year - 1
                    }
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
              <%= for {graduation_year, year_residents} <- residents_by_year(@unified_residents, @filter_year, @viewed_aca_year) do %>
                <% cohort_level = hd(year_residents).cohort_level %>
                <% initially_hidden = cohort_level not in 1..4 %>
                <tr
                  data-year-group={graduation_year}
                  data-cohort-graduation-year={graduation_year}
                  class={[
                    "border-t-2 border-gray-300 dark:border-gray-600",
                    if(initially_hidden, do: "hidden")
                  ]}
                >
                  <td
                    class="sticky left-0 z-20 bg-gray-100 dark:bg-gray-800 px-2 py-0.5 text-xs font-bold text-gray-500 dark:text-gray-300 uppercase tracking-widest border-r border-gray-200 dark:border-gray-700"
                    style={"width: #{@name_col_px}px; min-width: #{@name_col_px}px; max-width: #{@name_col_px}px"}
                  >
                    {cohort_separator_label(cohort_level, graduation_year)}
                  </td>
                  <td colspan="9999" class="bg-gray-100 dark:bg-gray-800"></td>
                </tr>
                <%= for resident <- year_residents do %>
                  <tr
                    data-cohort-graduation-year={graduation_year}
                    class={[
                      "hover:bg-gray-50 dark:hover:bg-gray-950 transition-colors border-b border-gray-100 dark:border-gray-700",
                      if(initially_hidden, do: "hidden")
                    ]}
                  >
                    <td
                      class="sticky left-0 z-20 bg-white dark:bg-gray-900 px-2 py-1 text-gray-700 dark:text-gray-200 font-medium border-r border-gray-200 dark:border-gray-700 overflow-hidden"
                      style={"width: #{@name_col_px}px; min-width: #{@name_col_px}px; max-width: #{@name_col_px}px"}
                      data-tour-resident-name="true"
                      data-cohort-graduation-year={graduation_year}
                    >
                      <.link
                        navigate={"/residents/#{resident.id}"}
                        class="hover:text-blue-600 dark:hover:text-blue-300 truncate block"
                      >
                        {resident.name}
                      </.link>
                    </td>
                    <%= for {colspan, rotation} <- resident.cells do %>
                      <% past = rotation != nil && Date.compare(rotation.end_date, @today) == :lt %>
                      <td
                        colspan={colspan}
                        class="px-0.5 py-0.5 text-center border-r border-gray-100 dark:border-gray-700"
                      >
                        <.rotation_cell rotation={rotation} past={past} />
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
          <p class="text-gray-500 dark:text-gray-300 mb-4">No schedule uploaded yet.</p>
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
      <%= if @rotation_modal do %>
        <div
          id="gantt-rotation-modal"
          role="dialog"
          aria-modal="true"
          aria-labelledby="gantt-rotation-modal-title"
          phx-window-keydown="close_rotation_details"
          phx-key="Escape"
          phx-mounted={JS.focus(to: "#gantt-close-details")}
          phx-remove={JS.focus(to: "#gantt-pill-#{@rotation_modal.cell_id}")}
          class="fixed inset-0 z-50 flex items-center justify-center p-4"
        >
          <div
            data-role="backdrop"
            phx-click="close_rotation_details"
            class="absolute inset-0 bg-black/40"
            aria-hidden="true"
          >
          </div>
          <.focus_wrap
            id="gantt-detail-focus"
            class="relative bg-white dark:bg-gray-900 rounded-xl shadow-xl max-w-2xl w-full max-h-[85vh] overflow-y-auto p-6"
          >
            <div class="flex items-start justify-between gap-4 mb-4">
              <div>
                <h2 id="gantt-rotation-modal-title" class="text-lg font-semibold">
                  {@rotation_modal.name} — {Rotations.rotation_type_label(
                    @rotation_modal.rotation_type
                  )}
                </h2>
                <p
                  id="gantt-rotation-dates"
                  data-start-date={@rotation_modal.start_date}
                  data-end-date={@rotation_modal.end_date}
                  class="text-sm text-gray-500 dark:text-gray-300"
                >
                  {Calendar.strftime(@rotation_modal.start_date, "%b %-d, %Y")}–{Calendar.strftime(
                    @rotation_modal.end_date,
                    "%b %-d, %Y"
                  )}
                </p>
              </div>
              <button
                id="gantt-close-details"
                type="button"
                aria-label="Close"
                phx-click="close_rotation_details"
                class="rounded p-2 hover:bg-gray-100 dark:hover:bg-gray-800 focus-visible:ring-2 focus-visible:ring-blue-500"
              >
                ×
              </button>
            </div>
            <DailyAssignments.activities
              id="gantt-daily-assignments"
              activities={@rotation_modal.activities}
            />
          </.focus_wrap>
        </div>
      <% end %>
    </div>
    """
  end

  # --- Private helpers ---

  @doc false
  def load_all_schedules(socket, schedules, today) do
    schedule_map = Map.new(schedules, &{&1.id, &1})
    schedule_ids = Enum.map(schedules, & &1.id)

    all_schedule_residents =
      schedule_ids
      |> Residents.list_residents_across_schedules()
      |> ResidentDisplayNames.apply_to_schedule_residents()

    residents_by_schedule = Enum.group_by(all_schedule_residents, & &1.schedule_id)
    sections = build_slot_sections(schedules, residents_by_schedule)
    all_slots = build_combined_slots(sections)

    unified_residents =
      build_unified_residents(all_schedule_residents, schedule_map, today)
      |> Enum.map(&Map.put(&1, :cells, cell_groups_unified(all_slots, &1.rotation_lookup)))

    assign(socket,
      schedules: schedules,
      all_slots: all_slots,
      unified_residents: unified_residents,
      rotation_modal: nil,
      filter_year: nil
    )
  end

  defp build_slot_sections(schedules, residents_by_schedule) do
    schedules
    |> Enum.map(fn schedule ->
      residents = Map.get(residents_by_schedule, schedule.id, [])

      %{
        schedule: schedule,
        slots: build_slots(residents),
        slot_offset: 0
      }
    end)
    |> assign_slot_offsets()
  end

  defp assign_slot_offsets(sections) do
    {sections_with_offsets, _} =
      Enum.map_reduce(sections, 0, fn section, offset ->
        {%{section | slot_offset: offset}, offset + length(section.slots)}
      end)

    sections_with_offsets
  end

  @doc """
  Builds a list of unified resident rows filtered to the 4 cohort classes
  active in today's academic year. Each cohort's level is derived from
  how many academic years have passed since they entered the program.

      iex> ResidencyScheduleWeb.ScheduleLive.Index.build_unified_residents([], %{}, ~D[2026-04-06])
      []
  """
  def build_unified_residents(all_schedule_residents, schedule_map, today) do
    aca_year = current_academic_year(today)

    all_schedule_residents
    |> Enum.group_by(& &1.resident_id)
    |> Enum.map(fn {_person_id, srs} ->
      row = build_person_row(srs, schedule_map, aca_year)
      level = aca_year - row.cohort_academic_year + row.cohort_residency_year
      Map.put(row, :cohort_level, level)
    end)
    |> Enum.sort_by(&{&1.graduation_year, &1.sort_number})
  end

  defp build_person_row(schedule_residents, schedule_map, current_aca_year) do
    sorted =
      Enum.sort_by(schedule_residents, fn sr ->
        schedule_map[sr.schedule_id].academic_year
      end)

    latest = List.last(sorted)
    earliest = hd(sorted)

    # Link to the schedule covering the current academic year if the resident
    # has one; otherwise pick the most recent schedule they appear in.
    detail_sr =
      Enum.find(sorted, latest, fn sr ->
        schedule_map[sr.schedule_id].academic_year == current_aca_year
      end)

    rotation_lookup = build_rotation_lookup(sorted)

    %{
      resident_id: latest.resident_id,
      id: detail_sr.id,
      name: latest.name,
      position_code: latest.position_code,
      current_year: latest.residency_year,
      sort_number: earliest.schedule_number,
      cohort_academic_year: schedule_map[earliest.schedule_id].academic_year,
      cohort_residency_year: earliest.residency_year,
      graduation_year:
        schedule_map[earliest.schedule_id].academic_year - earliest.residency_year + 4,
      rotation_lookup: rotation_lookup
    }
  end

  defp build_rotation_lookup(schedule_residents) do
    Map.new(schedule_residents, &{&1.schedule_id, &1.rotations})
  end

  defp residents_by_year(unified_residents, filter_year, viewed_aca_year) do
    unified_residents
    |> visible_residents(filter_year, viewed_aca_year)
    |> Enum.group_by(& &1.graduation_year)
    |> Enum.sort_by(fn {gy, _} -> gy end)
    |> Enum.reject(fn {_, rs} -> rs == [] end)
  end

  @doc """
  Returns the label for a cohort separator row.

      iex> ResidencyScheduleWeb.ScheduleLive.Index.cohort_separator_label(2, 2026)
      "c/o 2026"

      iex> ResidencyScheduleWeb.ScheduleLive.Index.cohort_separator_label(5, 2023)
      "c/o 2023"
  """
  def cohort_separator_label(_cohort_level, graduation_year) do
    "c/o #{graduation_year}"
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

  defp build_slots([]), do: []

  defp build_slots(residents) do
    residents
    |> Enum.flat_map(& &1.rotations)
    |> Rotations.date_slots()
  end

  @doc false
  def slot_header_label(start_date, end_date) do
    if start_date.month == end_date.month do
      "#{start_date.day}–#{end_date.day} #{Calendar.strftime(start_date, "%b")}"
    else
      "#{Calendar.strftime(start_date, "%-d %b")}–#{Calendar.strftime(end_date, "%-d %b")}"
    end
  end

  @doc """
  Groups calendar-adjacent slots within one schedule into cells by rotation type. Works with
  the unified all_slots list and rotations grouped by schedule ID. Legacy column-keyed lookups are also accepted.

      iex> all_slots = [{1, 0, ~D[2023-07-03], ~D[2023-07-09], true}, {1, 1, ~D[2023-07-10], ~D[2023-07-16], false}]
      iex> lookup = %{{1, 0} => %{rotation_type: "float", end_date: ~D[2023-07-09]}, {1, 1} => %{rotation_type: "float", end_date: ~D[2023-07-16]}}
      iex> [{count, rot}] = ResidencyScheduleWeb.ScheduleLive.Index.cell_groups_unified(all_slots, lookup)
      iex> {count, rot.rotation_type}
      {2, "float"}
  """
  def cell_groups_unified(all_slots, rotation_lookup) do
    all_slots
    |> Enum.map(fn {schedule_id, idx, start, last, _first?} ->
      {schedule_id, start, last, lookup_slot_rotation(rotation_lookup, schedule_id, idx, start)}
    end)
    |> Enum.chunk_while([], &chunk_adjacent_cells/2, fn
      [] -> {:cont, []}
      group -> {:cont, Enum.reverse(group), []}
    end)
    |> Enum.map(fn group ->
      {schedule_id, first, _, rotation} = hd(group)
      {_, _, last, _} = List.last(group)
      {length(group), annotate_cell(rotation, schedule_id, first, last)}
    end)
  end

  defp chunk_adjacent_cells(cell, []), do: {:cont, [cell]}

  defp chunk_adjacent_cells({schedule_id, first, _, rotation} = cell, [previous | _] = group) do
    {previous_schedule, _, previous_last, previous_rotation} = previous

    if schedule_id == previous_schedule and first == Date.add(previous_last, 1) and
         rotation_cell_key(rotation) == rotation_cell_key(previous_rotation) do
      {:cont, [cell | group]}
    else
      {:cont, Enum.reverse(group), [cell]}
    end
  end

  defp lookup_slot_rotation(lookup, schedule_id, idx, date) do
    case Map.get(lookup, schedule_id) do
      nil ->
        Map.get(lookup, {schedule_id, idx})

      rotations ->
        rotations
        |> Enum.filter(
          &(Date.compare(&1.start_date, date) != :gt and Date.compare(&1.end_date, date) != :lt)
        )
        |> Enum.sort_by(& &1.rotation_type)
        |> combine_concurrent_rotations()
    end
  end

  defp annotate_cell(nil, _, _, _), do: nil

  defp annotate_cell(%{rotations: rotations} = cell, schedule_id, first, last) do
    %{
      cell
      | rotations: Enum.map(rotations, &annotate_cell(&1, schedule_id, first, last)),
        end_date: last
    }
  end

  defp annotate_cell(rotation, schedule_id, first, last) do
    token =
      {schedule_id, Map.get(rotation, :id), first, last}
      |> :erlang.term_to_binary()
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.url_encode64(padding: false)

    Map.merge(rotation, %{
      schedule_id: schedule_id,
      start_date: first,
      end_date: last,
      cell_id: token
    })
  end

  defp find_rotation_details(assigns, token) when is_binary(token) do
    assigns.unified_residents
    |> visible_residents(assigns.filter_year, assigns.viewed_aca_year)
    |> Enum.find_value(&find_resident_cell(&1, token))
    |> load_rotation_activities()
  end

  defp find_rotation_details(_, _), do: nil

  defp find_resident_cell(resident, token) do
    resident.cells
    |> Enum.flat_map(fn {_, cell} -> cell_rotations(cell) end)
    |> Enum.find(&(&1.cell_id == token))
    |> case do
      nil -> nil
      rotation -> Map.put(rotation, :name, resident.name)
    end
  end

  defp cell_rotations(nil), do: []
  defp cell_rotations(%{rotations: rotations}), do: rotations
  defp cell_rotations(rotation), do: [rotation]

  defp load_rotation_activities(nil), do: nil

  defp load_rotation_activities(rotation) do
    activities =
      DetailedSchedules.list_for_resident_range(
        rotation.schedule_resident_id,
        rotation.start_date,
        rotation.end_date
      )

    Map.put(rotation, :activities, activities)
  end

  defp combine_concurrent_rotations([]), do: nil
  defp combine_concurrent_rotations([rotation]), do: rotation

  defp combine_concurrent_rotations(rotations) do
    %{rotations: rotations, end_date: rotations |> Enum.map(& &1.end_date) |> Enum.max(Date)}
  end

  defp rotation_cell_key(nil), do: :blank
  defp rotation_cell_key(%{rotations: rotations}), do: Enum.map(rotations, & &1.rotation_type)
  defp rotation_cell_key(rotation), do: rotation.rotation_type

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

  defp rotation_cell(assigns) do
    ~H"""
    <%= if @rotation do %>
      <%= for rotation <- cell_rotations(@rotation) do %>
        <button
          id={"gantt-pill-#{rotation.cell_id}"}
          type="button"
          data-rotation-id={rotation.id}
          phx-click="open_rotation_details"
          phx-value-cell-id={rotation.cell_id}
          aria-haspopup="dialog"
          aria-label={"View #{Rotations.rotation_type_label(rotation.rotation_type)} details"}
          class={[
            "inline-block rounded px-1 py-0.5 text-xs font-medium whitespace-nowrap cursor-pointer hover:ring-1 focus-visible:ring-2 focus-visible:ring-blue-500",
            @past && "opacity-40",
            Rotations.rotation_type_color(rotation.rotation_type)
          ]}
        >
          <span>{abbrev(rotation.rotation_type)}</span>
        </button>
      <% end %>
    <% else %>
      <span class="text-gray-200 dark:text-gray-600">–</span>
    <% end %>
    """
  end

  @abbrev_map %{
    "leave_of_absence" => "LOA",
    "admin" => "ADMIN",
    "admin_mfm" => "ADMIN/MFM",
    "cob" => "COB",
    "gog_colpo" => "GOG/Colpo",
    "mfm" => "MFM",
    "mfm_pain" => "MFM/pain",
    "mfm_pm" => "MFM PM",
    "orientation" => "Orient",
    "oncology_orientation" => "ONC (orient)",
    "highland_obstetrics_orientation" => "HHOB (orient)",
    "strong_gynecology_orientation" => "GYN (orient)",
    "highland_gynecology_orientation" => "HGYN (orient)",
    "strong_obstetrics_orientation" => "OB (orient)",
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

  defp visible_residents(unified_residents, nil, _viewed_aca_year), do: unified_residents

  defp visible_residents(unified_residents, level, viewed_aca_year) do
    target_grad_year = viewed_aca_year + 4 - level
    Enum.filter(unified_residents, &(&1.graduation_year == target_grad_year))
  end

  @doc """
  Returns the current date. In test, this can be overridden via application env
  `:residency_schedule, :current_date` to make tests deterministic.

      iex> is_struct(ResidencyScheduleWeb.ScheduleLive.Index.current_date(), Date)
      true
  """
  def current_date do
    Application.get_env(:residency_schedule, :current_date, Date.utc_today())
  end

  @doc """
  Derives the academic year start integer from a date. The residency academic
  year runs July 1 through June 30.

      iex> ResidencyScheduleWeb.ScheduleLive.Index.current_academic_year(~D[2026-07-01])
      2026

      iex> ResidencyScheduleWeb.ScheduleLive.Index.current_academic_year(~D[2026-06-30])
      2025

      iex> ResidencyScheduleWeb.ScheduleLive.Index.current_academic_year(~D[2026-04-06])
      2025
  """
  def current_academic_year(date) do
    if date.month >= 7, do: date.year, else: date.year - 1
  end

  defp to_integer(value) when is_integer(value), do: value
  defp to_integer(value) when is_binary(value), do: String.to_integer(value)

  defp filter_tab_class(current, value) do
    base = "px-3 py-1 rounded-full text-sm font-medium transition-colors"

    if current == value,
      do: "#{base} bg-blue-600 text-white",
      else:
        "#{base} bg-gray-100 dark:bg-gray-800 text-gray-700 dark:text-gray-200 hover:bg-gray-200 dark:hover:bg-gray-700"
  end

  # Deleting a schedule is destructive, so the admin must confirm with their
  # own account password — a role check alone is not enough.
  defp authorized_to_delete?(user, password) do
    Accounts.User.admin?(user) and
      match?({:ok, _}, Accounts.authenticate_by_password(user.email, password))
  end

  defp delete_error_message(user) do
    if user && Accounts.has_password?(user) do
      "Incorrect password."
    else
      "Set a password for your account on the Admin page first."
    end
  end

  defp refresh_after_delete(socket) do
    socket =
      case Schedules.list_schedules() do
        [] ->
          assign(socket, schedules: [], all_slots: [], unified_residents: [], filter_year: nil)

        remaining ->
          load_all_schedules(socket, remaining, current_date())
      end

    assign(socket, delete_confirm_id: nil, delete_error: nil)
  end
end
