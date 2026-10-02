defmodule ResidencyScheduleWeb.BuilderLive.Index do
  use ResidencyScheduleWeb, :live_view

  on_mount {ResidencyScheduleWeb.UserAuth, :ensure_admin}

  alias ResidencySchedule.Rotations
  alias ResidencySchedule.ScheduleBuilder

  # Fixed pixel widths for sticky label columns — must match left-[Xpx] values below.
  @id_col_px 72
  @name_col_px 128

  @abbrev_map %{
    ambulatory: "AMB",
    away_rotation: "AWAY",
    elective: "Elec",
    float: "FLOAT",
    strong_gynecology: "GYN",
    highland_gynecology: "HGYN",
    highland_obstetrics: "HHOB",
    highland_night_float: "HNF",
    highland_weekend_days: "HWD",
    highland_weekend_nights: "HWN",
    night_float: "NF",
    strong_obstetrics: "OB",
    oncology: "ONC",
    post_call: "P",
    rei: "REI",
    strong_weekend_days: "SWD",
    strong_weekend_nights: "SWN",
    swing: "Swing",
    urogynecology: "UG",
    ultrasound: "US",
    vacation: "Vac"
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       academic_year_input: "#{Date.utc_today().year}",
       builder_state: nil,
       filter_year: nil,
       picker: nil,
       save_state: :idle,
       r1_name_suggestions: [],
       duplicate_name_indices: MapSet.new(),
       history: []
     )}
  end

  @impl true
  def handle_event("set_year", %{"year" => year}, socket) do
    {:noreply, assign(socket, academic_year_input: year)}
  end

  @impl true
  def handle_event("generate", _params, socket) do
    case Integer.parse(socket.assigns.academic_year_input) do
      {year, ""} ->
        {:ok, state} = ScheduleBuilder.generate(year)
        r1_suggestions = ScheduleBuilder.prior_year_names_for_level(year, 1)

        {:noreply,
         assign(socket,
           builder_state: state,
           filter_year: nil,
           picker: nil,
           save_state: :idle,
           r1_name_suggestions: r1_suggestions,
           duplicate_name_indices: duplicate_name_indices(state),
           history: []
         )}

      _ ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("resolve", _params, socket) do
    resolved = ScheduleBuilder.resolve_violations(socket.assigns.builder_state)
    {:noreply, push_history(socket) |> assign(builder_state: resolved, save_state: :idle)}
  end

  @impl true
  def handle_event("undo", _params, socket) do
    case socket.assigns.history do
      [] ->
        {:noreply, socket}

      [prev | rest] ->
        {:noreply,
         assign(socket,
           builder_state: prev,
           history: rest,
           save_state: :idle,
           duplicate_name_indices: duplicate_name_indices(prev)
         )}
    end
  end

  @impl true
  def handle_event("filter_year", %{"year" => year}, socket) do
    filter_year = if year == "all", do: nil, else: String.to_integer(year)
    {:noreply, assign(socket, filter_year: filter_year)}
  end

  @impl true
  def handle_event("open_picker", %{"res-idx" => res_idx, "slot-idx" => slot_idx}, socket) do
    picker = %{res_idx: String.to_integer(res_idx), slot_idx: String.to_integer(slot_idx)}
    {:noreply, assign(socket, picker: picker)}
  end

  @impl true
  def handle_event("close_picker", _params, socket) do
    {:noreply, assign(socket, picker: nil)}
  end

  @impl true
  def handle_event("set_rotation", %{"rotation" => rotation}, socket) do
    %{picker: %{res_idx: res_idx, slot_idx: slot_idx}, builder_state: state} = socket.assigns
    rotation_atom = String.to_existing_atom(rotation)
    updated_state = ScheduleBuilder.set_rotation(state, res_idx, slot_idx, rotation_atom)

    {:noreply,
     push_history(socket) |> assign(builder_state: updated_state, picker: nil, save_state: :idle)}
  end

  @impl true
  def handle_event("clear_rotation", _params, socket) do
    %{picker: %{res_idx: res_idx, slot_idx: slot_idx}, builder_state: state} = socket.assigns
    updated_state = ScheduleBuilder.clear_rotation(state, res_idx, slot_idx)

    {:noreply,
     push_history(socket) |> assign(builder_state: updated_state, picker: nil, save_state: :idle)}
  end

  @impl true
  def handle_event("swap_residents", %{"from_idx" => from_idx, "to_idx" => to_idx}, socket) do
    updated_state =
      ScheduleBuilder.move_resident_name(
        socket.assigns.builder_state,
        String.to_integer(from_idx),
        String.to_integer(to_idx)
      )

    {:noreply,
     push_history(socket)
     |> assign(
       builder_state: updated_state,
       duplicate_name_indices: duplicate_name_indices(updated_state),
       save_state: :idle
     )}
  end

  @impl true
  def handle_event("rename_resident", %{"res-idx" => res_idx, "value" => name}, socket) do
    updated_state =
      ScheduleBuilder.rename_resident(
        socket.assigns.builder_state,
        String.to_integer(res_idx),
        String.trim(name)
      )

    {:noreply,
     push_history(socket)
     |> assign(
       builder_state: updated_state,
       duplicate_name_indices: duplicate_name_indices(updated_state),
       save_state: :idle
     )}
  end

  @impl true
  def handle_event("save", _params, socket) do
    socket = assign(socket, save_state: :saving)

    case ScheduleBuilder.save(socket.assigns.builder_state) do
      {:ok, _result} -> {:noreply, assign(socket, save_state: :saved)}
      {:error, reason} -> {:noreply, assign(socket, save_state: {:error, reason})}
    end
  end

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :id_col_px, @id_col_px)
    assigns = assign(assigns, :name_col_px, @name_col_px)
    assigns = assign(assigns, :abbrev_map, @abbrev_map)

    ~H"""
    <div class="min-h-screen bg-gray-50 relative">
      <%!-- Toolbar --%>
      <div class="bg-white border-b border-gray-200 px-4 sm:px-6 py-3 flex flex-wrap items-center gap-3 sticky top-14 z-40">
        <%!-- Generate from scratch --%>
        <form phx-submit="generate" class="flex items-center gap-2">
          <input
            type="number"
            name="year"
            value={@academic_year_input}
            phx-change="set_year"
            min="2020"
            max="2040"
            class="border border-gray-300 rounded px-2 py-1 text-sm w-24 focus:outline-none focus:ring-1 focus:ring-blue-400"
            placeholder="Start year"
          />
          <%= case Integer.parse(@academic_year_input) do %>
            <% {y, ""} -> %>
              <span class="text-xs text-gray-500 font-medium tabular-nums">{y}–{y + 1}</span>
            <% _ -> %>
              <span></span>
          <% end %>
          <button
            type="submit"
            class="px-3 py-1.5 bg-blue-600 text-white rounded text-sm font-medium hover:bg-blue-700 transition-colors"
          >
            Generate new schedule
          </button>
        </form>

        <%!-- Warning status / resolve button --%>
        <%= if @builder_state do %>
          <% duty_count = length(@builder_state.duty_warnings) %>
          <% cov_count = length(@builder_state.coverage_warnings) %>
          <% placement_count = length(@builder_state.placement_warnings) %>
          <% warning_count = duty_count + cov_count + placement_count %>
          <span class="w-px h-4 bg-gray-200"></span>
          <%= if warning_count > 0 do %>
            <span class="inline-flex items-center gap-1 px-2.5 py-1 bg-amber-100 text-amber-800 rounded-full text-xs font-medium">
              <svg class="w-3 h-3" fill="currentColor" viewBox="0 0 20 20">
                <path
                  fill-rule="evenodd"
                  d="M8.485 2.495c.673-1.167 2.357-1.167 3.03 0l6.28 10.875c.673 1.167-.17 2.625-1.516 2.625H3.72c-1.347 0-2.189-1.458-1.515-2.625L8.485 2.495zM10 5a.75.75 0 01.75.75v3.5a.75.75 0 01-1.5 0v-3.5A.75.75 0 0110 5zm0 9a1 1 0 100-2 1 1 0 000 2z"
                  clip-rule="evenodd"
                />
              </svg>
              {warning_count} warning{if warning_count != 1, do: "s"}
            </span>
            <%= if duty_count > 0 do %>
              <button
                phx-click="resolve"
                class="px-3 py-1.5 bg-red-600 text-white rounded text-sm font-medium hover:bg-red-700 transition-colors"
              >
                Resolve Violations
              </button>
            <% end %>
          <% else %>
            <span class="inline-flex items-center gap-1 px-2.5 py-1 bg-green-100 text-green-800 rounded-full text-xs font-medium">
              No warnings
            </span>
          <% end %>
          <span class="w-px h-4 bg-gray-200"></span>
          <button
            phx-click="undo"
            disabled={@history == []}
            class={[
              "inline-flex items-center gap-1 px-2.5 py-1 rounded text-xs font-medium transition-colors",
              if(@history == [],
                do: "text-gray-300 cursor-not-allowed",
                else: "text-gray-600 hover:bg-gray-100"
              )
            ]}
            title="Undo (Ctrl+Z)"
          >
            <svg class="w-3.5 h-3.5" fill="none" stroke="currentColor" viewBox="0 0 24 24">
              <path
                stroke-linecap="round"
                stroke-linejoin="round"
                stroke-width="2"
                d="M3 10h10a8 8 0 018 8v2M3 10l6 6M3 10l6-6"
              />
            </svg>
            Undo
          </button>
        <% end %>
      </div>

      <%= if @builder_state do %>
        <%!-- Warning banner --%>
        <%= if length(@builder_state.duty_warnings) > 0 or length(@builder_state.coverage_warnings) > 0 or length(@builder_state.placement_warnings) > 0 do %>
          <div class="bg-amber-50 border-b border-amber-200 px-4 sm:px-6 py-2">
            <%= if length(@builder_state.duty_warnings) > 0 do %>
              <p class="text-xs font-semibold text-amber-800 mb-1">
                Duty Hour Violations (80 hr/wk avg exceeded):
              </p>
              <div class="flex flex-wrap gap-1 mb-1">
                <%= for v <- Enum.take(@builder_state.duty_warnings, 30) do %>
                  <% resident = Enum.at(@builder_state.residents, v.resident_index) %>
                  <span class="inline-block px-2 py-0.5 bg-amber-200 text-amber-900 rounded text-xs">
                    {resident && resident.position_code}: {Float.round(v.weekly_avg * 1.0, 1)} hr/wk @ slot {v.window_start_slot}
                  </span>
                <% end %>
                <%= if length(@builder_state.duty_warnings) > 30 do %>
                  <span class="text-xs text-amber-700">
                    +{length(@builder_state.duty_warnings) - 30} more
                  </span>
                <% end %>
              </div>
            <% end %>
            <%= if length(@builder_state.coverage_warnings) > 0 do %>
              <p class="text-xs font-semibold text-red-800 mb-1">Coverage Shortfalls:</p>
              <div class="flex flex-wrap gap-1">
                <%= for w <- Enum.take(@builder_state.coverage_warnings, 20) do %>
                  <span class="inline-block px-2 py-0.5 bg-red-100 text-red-900 rounded text-xs">
                    Slot {w.slot_index}: {abbrev_atom(w.rotation_type, @abbrev_map)} {w.actual}/{w.required}
                  </span>
                <% end %>
                <%= if length(@builder_state.coverage_warnings) > 20 do %>
                  <span class="text-xs text-red-700">
                    +{length(@builder_state.coverage_warnings) - 20} more
                  </span>
                <% end %>
              </div>
            <% end %>
            <%= if length(@builder_state.placement_warnings) > 0 do %>
              <p class="text-xs font-semibold text-purple-800 mb-1 mt-1">Wrong Slot Type:</p>
              <div class="flex flex-wrap gap-1">
                <%= for w <- Enum.take(@builder_state.placement_warnings, 20) do %>
                  <% resident = Enum.at(@builder_state.residents, w.resident_index) %>
                  <span class="inline-block px-2 py-0.5 bg-purple-100 text-purple-900 rounded text-xs">
                    {resident && resident.position_code} slot {w.slot_index}: {abbrev_atom(
                      w.rotation_type,
                      @abbrev_map
                    )} ({w.reason})
                  </span>
                <% end %>
                <%= if length(@builder_state.placement_warnings) > 20 do %>
                  <span class="text-xs text-purple-700">
                    +{length(@builder_state.placement_warnings) - 20} more
                  </span>
                <% end %>
              </div>
            <% end %>
          </div>
        <% end %>

        <%!-- Year filter tabs --%>
        <div class="px-4 sm:px-6 py-3 bg-white border-b border-gray-200 flex flex-wrap items-center gap-2">
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
          <span
            id="gantt-year-indicator"
            class="ml-auto text-sm font-semibold text-gray-500 tabular-nums"
          >
          </span>
        </div>

        <%!-- Gantt grid --%>
        <% residents_by_year = group_residents_by_year(@builder_state.residents) %>
        <% duty_warned_set = duty_warned_residents(@builder_state.duty_warnings) %>
        <% coverage_warned_set = coverage_warned_slots(@builder_state.coverage_warnings) %>
        <div id="gantt-scroll" phx-hook="YearTracker" class="overflow-x-auto">
          <table class="border-separate border-spacing-0 text-xs">
            <thead>
              <tr class="bg-gray-100 sticky top-0 z-30">
                <th
                  class="sticky left-0 z-40 bg-gray-100 px-2 py-2 text-left font-semibold text-gray-600 border-b border-r border-gray-300 whitespace-nowrap"
                  style={"width: #{@id_col_px}px; min-width: #{@id_col_px}px; max-width: #{@id_col_px}px"}
                >
                  ID
                </th>
                <th
                  class="sticky z-40 bg-gray-100 px-2 py-2 text-left font-semibold text-gray-600 border-b border-r border-gray-300 whitespace-nowrap"
                  style={"left: #{@id_col_px}px; width: #{@name_col_px}px; min-width: #{@name_col_px}px; max-width: #{@name_col_px}px"}
                >
                  Name
                </th>
                <%= for slot <- @builder_state.slots do %>
                  <th
                    class={[
                      "px-1 py-2 text-center font-medium border-b border-gray-200 whitespace-nowrap",
                      if(MapSet.member?(coverage_warned_set, slot.slot_index),
                        do: "text-red-500 bg-red-50",
                        else: "text-gray-500"
                      )
                    ]}
                    style="min-width: 44px"
                    data-slot-year={slot.start_date.year}
                  >
                    {slot_header_label(slot.start_date, slot.end_date)}
                  </th>
                <% end %>
              </tr>
            </thead>
            <tbody>
              <%= for {year, residents} <- visible_residents(residents_by_year, @filter_year) do %>
                <tr class="bg-gray-50">
                  <td
                    colspan={2 + length(@builder_state.slots)}
                    class="px-3 py-1 text-xs font-semibold text-gray-500 uppercase tracking-wide border-b border-gray-200"
                  >
                    R{year} Residents
                  </td>
                </tr>
                <%= for {resident, res_idx} <- residents do %>
                  <tr class="hover:bg-gray-50 border-b border-gray-100">
                    <td
                      class="sticky left-0 z-20 bg-white px-2 py-1 font-mono text-gray-500 border-r border-gray-200"
                      style={"width: #{@id_col_px}px; min-width: #{@id_col_px}px; max-width: #{@id_col_px}px"}
                    >
                      {resident.position_code}
                    </td>
                    <td
                      class="group sticky z-20 bg-white border-r border-gray-200 cursor-grab select-none"
                      style={"left: #{@id_col_px}px; width: #{@name_col_px}px; min-width: #{@name_col_px}px; max-width: #{@name_col_px}px"}
                      draggable="true"
                      data-res-idx={res_idx}
                      data-res-year={resident.residency_year}
                      data-has-error={to_string(MapSet.member?(@duplicate_name_indices, res_idx))}
                      id={"name-cell-#{res_idx}"}
                      phx-hook="ResidentDrag"
                    >
                      <div class="flex items-center gap-0.5 px-1 py-0.5 bg-white name-cell-inner">
                        <svg
                          class="shrink-0 text-gray-300 group-hover:text-gray-400 transition-colors"
                          width="8"
                          height="14"
                          viewBox="0 0 8 14"
                          fill="currentColor"
                          aria-hidden="true"
                        >
                          <circle cx="2" cy="2" r="1.2" />
                          <circle cx="6" cy="2" r="1.2" />
                          <circle cx="2" cy="7" r="1.2" />
                          <circle cx="6" cy="7" r="1.2" />
                          <circle cx="2" cy="12" r="1.2" />
                          <circle cx="6" cy="12" r="1.2" />
                        </svg>
                        <% is_dup = MapSet.member?(@duplicate_name_indices, res_idx) %>
                        <input
                          type="text"
                          list={if resident.residency_year == 1, do: "r1-names", else: nil}
                          value={resident.name}
                          phx-blur="rename_resident"
                          phx-value-res-idx={res_idx}
                          name="name"
                          title={if is_dup, do: "Name must be unique", else: nil}
                          class={[
                            "w-full text-xs font-medium bg-transparent rounded px-1 py-0.5 focus:outline-none focus:bg-white transition-colors cursor-text select-text",
                            if is_dup do
                              "border border-red-400 text-red-700 hover:border-red-500 focus:border-red-500"
                            else
                              "border border-transparent text-gray-700 hover:border-gray-300 focus:border-blue-400"
                            end
                          ]}
                          placeholder="Name"
                        />
                      </div>
                    </td>
                    <%= for slot <- @builder_state.slots do %>
                      <% rotation_type =
                        Map.get(@builder_state.assignments, {res_idx, slot.slot_index}) %>
                      <% has_warn =
                        MapSet.member?(duty_warned_set, res_idx) or
                          MapSet.member?(coverage_warned_set, slot.slot_index) %>
                      <td
                        class={[
                          "px-0.5 py-0.5 text-center border-r border-gray-100 cursor-pointer hover:bg-blue-50 transition-colors",
                          if(has_warn, do: "ring-1 ring-inset ring-amber-300")
                        ]}
                        phx-click="open_picker"
                        phx-value-res-idx={res_idx}
                        phx-value-slot-idx={slot.slot_index}
                      >
                        {render_builder_cell(rotation_type, @abbrev_map)}
                      </td>
                    <% end %>
                  </tr>
                <% end %>
              <% end %>
            </tbody>
          </table>
        </div>

        <%!-- Datalist for R1 name autocomplete --%>
        <%= if length(@r1_name_suggestions) > 0 do %>
          <datalist id="r1-names">
            <%= for name <- @r1_name_suggestions do %>
              <option value={name} />
            <% end %>
          </datalist>
        <% end %>

        <%!-- Footer save bar --%>
        <div class="sticky bottom-0 bg-white border-t border-gray-200 px-4 sm:px-6 py-3 flex items-center gap-3 z-30">
          <button
            phx-click="save"
            disabled={
              @save_state == :saving or not MapSet.equal?(@duplicate_name_indices, MapSet.new())
            }
            class={[
              "px-5 py-2 rounded-md text-sm font-medium transition-colors",
              if not MapSet.equal?(@duplicate_name_indices, MapSet.new()) do
                "bg-gray-300 text-gray-500 cursor-not-allowed"
              else
                case @save_state do
                  :saving -> "bg-gray-300 text-gray-500 cursor-not-allowed"
                  :saved -> "bg-green-500 text-white"
                  _ -> "bg-green-600 text-white hover:bg-green-700"
                end
              end
            ]}
          >
            {case @save_state do
              :saving ->
                "Saving…"

              :saved ->
                "Saved!"

              {:error, _} ->
                "Save Failed — Retry"

              :idle ->
                "Save as Schedule #{@builder_state.academic_year}–#{@builder_state.academic_year + 1}"
            end}
          </button>
          <%= if not MapSet.equal?(@duplicate_name_indices, MapSet.new()) do %>
            <span class="text-sm text-red-600">Resolve duplicate names before saving.</span>
          <% end %>
          <%= if match?({:error, _}, @save_state) do %>
            <% {:error, reason} = @save_state %>
            <span class="text-sm text-red-600">{inspect(reason)}</span>
          <% end %>
          <%= if @save_state == :saved do %>
            <span class="text-sm text-green-700">
              Schedule saved — view it in the main schedule view.
            </span>
          <% end %>
        </div>
      <% else %>
        <div class="flex flex-col items-center justify-center py-24 text-center">
          <p class="text-gray-500 mb-2">
            Enter an academic year and click "Generate new schedule" to build a draft.
          </p>
        </div>
      <% end %>

      <%!-- Slide-in picker panel --%>
      <%= if @picker && @builder_state do %>
        <% res_idx = @picker.res_idx %>
        <% slot_idx = @picker.slot_idx %>
        <% resident = Enum.at(@builder_state.residents, res_idx) %>
        <% current_rotation = Map.get(@builder_state.assignments, {res_idx, slot_idx}) %>
        <% slot = Enum.find(@builder_state.slots, &(&1.slot_index == slot_idx)) %>
        <% valid_rotations = ScheduleBuilder.valid_rotations_for_slot(resident.residency_year, slot) %>
        <div class="fixed inset-0 bg-black/20 z-50" phx-click="close_picker"></div>
        <div class="fixed right-0 top-0 h-full w-72 bg-white shadow-xl z-50 flex flex-col">
          <div class="px-4 py-3 border-b border-gray-200 flex items-center justify-between">
            <div>
              <p class="text-sm font-semibold text-gray-800">{resident.position_code}</p>
              <p class="text-xs text-gray-500">Slot {slot_idx}</p>
            </div>
            <button
              phx-click="close_picker"
              class="p-1.5 rounded hover:bg-gray-100 text-gray-400 hover:text-gray-600 transition-colors"
            >
              &times;
            </button>
          </div>
          <div class="flex-1 overflow-y-auto px-3 py-3">
            <p class="text-xs font-medium text-gray-500 uppercase tracking-wide mb-2">
              Select Rotation
            </p>
            <div class="flex flex-col gap-1">
              <%= for rotation_type <- valid_rotations do %>
                <% color = Rotations.rotation_type_color(Atom.to_string(rotation_type)) %>
                <% is_current = rotation_type == current_rotation %>
                <button
                  phx-click="set_rotation"
                  phx-value-rotation={rotation_type}
                  class={[
                    "flex items-center gap-2 px-3 py-2 rounded-md text-sm transition-colors text-left w-full",
                    if(is_current, do: "ring-2 ring-blue-500 bg-blue-50", else: "hover:bg-gray-50")
                  ]}
                >
                  <span class={"inline-block rounded px-1.5 py-0.5 text-xs font-medium #{color}"}>
                    {abbrev_atom(rotation_type, @abbrev_map)}
                  </span>
                  <span class="text-gray-700 flex-1">
                    {Rotations.rotation_type_label(Atom.to_string(rotation_type))}
                  </span>
                  <%= if is_current do %>
                    <span class="text-blue-500 text-xs font-medium">Current</span>
                  <% end %>
                </button>
              <% end %>
            </div>
            <%= if current_rotation do %>
              <div class="mt-3 pt-3 border-t border-gray-100">
                <button
                  phx-click="clear_rotation"
                  class="flex items-center gap-2 px-3 py-2 rounded-md text-sm text-red-600 hover:bg-red-50 transition-colors w-full text-left"
                >
                  <span class="text-red-400">✕</span> Clear assignment
                </button>
              </div>
            <% end %>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  # --- Private helpers ---

  defp group_residents_by_year(residents) do
    residents
    |> Enum.with_index()
    |> Enum.group_by(fn {r, _idx} -> r.residency_year end)
  end

  defp visible_residents(residents_by_year, nil) do
    Enum.sort_by(residents_by_year, &elem(&1, 0))
  end

  defp visible_residents(residents_by_year, year) do
    residents_by_year
    |> Enum.filter(fn {y, _} -> y == year end)
    |> Enum.sort_by(&elem(&1, 0))
  end

  defp duty_warned_residents(duty_warnings) do
    MapSet.new(duty_warnings, & &1.resident_index)
  end

  defp coverage_warned_slots(coverage_warnings) do
    MapSet.new(coverage_warnings, & &1.slot_index)
  end

  defp slot_header_label(start_date, end_date) do
    if start_date.month == end_date.month do
      "#{start_date.day}–#{end_date.day} #{Calendar.strftime(start_date, "%b")}"
    else
      "#{Calendar.strftime(start_date, "%-d %b")}–#{Calendar.strftime(end_date, "%-d %b")}"
    end
  end

  defp abbrev_atom(rotation_type, abbrev_map) do
    Map.get(abbrev_map, rotation_type, Atom.to_string(rotation_type))
  end

  defp render_builder_cell(nil, _abbrev_map) do
    Phoenix.HTML.raw(~s(<span class="text-gray-200">–</span>))
  end

  defp render_builder_cell(rotation_type, abbrev_map) do
    color = Rotations.rotation_type_color(Atom.to_string(rotation_type))
    abbrev = Map.get(abbrev_map, rotation_type, Atom.to_string(rotation_type))

    Phoenix.HTML.raw(
      ~s(<span class="inline-block rounded px-1 py-0.5 text-xs font-medium whitespace-nowrap #{color}">#{abbrev}</span>)
    )
  end

  defp filter_tab_class(current, value) do
    base = "px-3 py-1 rounded-full text-sm font-medium transition-colors"

    if current == value,
      do: "#{base} bg-blue-600 text-white",
      else: "#{base} bg-gray-100 text-gray-700 hover:bg-gray-200"
  end

  defp push_history(socket) do
    history = [socket.assigns.builder_state | socket.assigns.history] |> Enum.take(50)
    assign(socket, history: history)
  end

  defp duplicate_name_indices(nil), do: MapSet.new()

  defp duplicate_name_indices(builder_state) do
    builder_state.residents
    |> Enum.with_index()
    |> Enum.group_by(fn {r, _i} -> String.downcase(String.trim(r.name)) end)
    |> Enum.filter(fn {name, entries} -> name != "" and length(entries) > 1 end)
    |> Enum.flat_map(fn {_name, entries} -> Enum.map(entries, fn {_r, i} -> i end) end)
    |> MapSet.new()
  end
end
