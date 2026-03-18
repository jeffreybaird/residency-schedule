defmodule ResidencyScheduleWeb.AdminLive.Index do
  use ResidencyScheduleWeb, :live_view

  alias ResidencySchedule.Schedules
  alias ResidencySchedule.Residents
  alias ResidencySchedule.Rotations
  alias ResidencySchedule.ShiftOverrides

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       schedules: Schedules.list_schedules(),
       delete_confirm_id: nil,
       existing_overrides: ShiftOverrides.list_all_overrides(),
       override_rotation_type: nil,
       override_start_date: nil,
       override_end_date: nil,
       available_rotations: [],
       override_rotation_id: nil,
       available_covering_residents: [],
       override_covering_resident_id: nil,
       override_error: nil,
       override_success: nil
     )}
  end

  @impl true
  def handle_event("request_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, delete_confirm_id: String.to_integer(id))}
  end

  @impl true
  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, delete_confirm_id: nil)}
  end

  @impl true
  def handle_event("confirm_delete", %{"id" => id}, socket) do
    Schedules.delete_schedule(String.to_integer(id))
    {:noreply, assign(socket, schedules: Schedules.list_schedules(), delete_confirm_id: nil)}
  end

  @impl true
  def handle_event("override_change", params, socket) do
    # phx-change on a form sends ALL current field values, so read directly from params.
    # nilify_empty treats "" and nil as absent — no || fallback needed.
    rotation_type = nilify_empty(params["rotation_type"])
    start_date = parse_date(params["start_date"])
    end_date = parse_date(params["end_date"])
    rotation_id = nilify_empty(params["rotation_id"])
    covering_id = nilify_empty(params["covering_resident_id"])

    available =
      if rotation_type && start_date && end_date &&
           Date.compare(start_date, end_date) != :gt do
        ShiftOverrides.list_rotations_for_type_in_range(rotation_type, start_date, end_date)
      else
        []
      end

    covering_residents =
      case rotation_id && Enum.find(available, fn rot -> to_string(rot.id) == rotation_id end) do
        nil -> []
        rot -> Residents.list_residents_for_schedule(rot.schedule_resident.schedule_id)
      end

    {:noreply,
     assign(socket,
       override_rotation_type: rotation_type,
       override_start_date: start_date,
       override_end_date: end_date,
       available_rotations: available,
       override_rotation_id: rotation_id,
       available_covering_residents: covering_residents,
       override_covering_resident_id: covering_id,
       override_error: nil,
       override_success: nil
     )}
  end

  @impl true
  def handle_event("save_override", _params, socket) do
    with rotation_id when rotation_id not in [nil, ""] <- socket.assigns.override_rotation_id,
         covering_id when covering_id not in [nil, ""] <- socket.assigns.override_covering_resident_id,
         start_date when not is_nil(start_date) <- socket.assigns.override_start_date,
         end_date when not is_nil(end_date) <- socket.assigns.override_end_date do
      attrs = %{
        rotation_id: String.to_integer(rotation_id),
        covering_schedule_resident_id: String.to_integer(covering_id),
        override_start_date: start_date,
        override_end_date: end_date
      }

      case ShiftOverrides.create_override(attrs) do
        {:ok, _} ->
          {:noreply,
           assign(socket,
             existing_overrides: ShiftOverrides.list_all_overrides(),
             override_rotation_type: nil,
             override_start_date: nil,
             override_end_date: nil,
             available_rotations: [],
             override_rotation_id: nil,
             available_covering_residents: [],
             override_covering_resident_id: nil,
             override_error: nil,
             override_success: "Override saved."
           )}

        {:error, changeset} ->
          msg = changeset.errors |> Enum.map_join(", ", fn {f, {m, _}} -> "#{f}: #{m}" end)
          {:noreply, assign(socket, override_error: msg, override_success: nil)}
      end
    else
      _ ->
        {:noreply, assign(socket, override_error: "Please fill in all fields.", override_success: nil)}
    end
  end

  @impl true
  def handle_event("delete_override", %{"id" => id}, socket) do
    ShiftOverrides.delete_override(String.to_integer(id))
    {:noreply, assign(socket, existing_overrides: ShiftOverrides.list_all_overrides())}
  end

  defp nilify_empty(nil), do: nil
  defp nilify_empty(""), do: nil
  defp nilify_empty(val), do: val

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil
  defp parse_date(%Date{} = d), do: d

  defp parse_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto py-10 px-4">
      <h1 class="text-2xl font-bold text-gray-800 mb-8">Admin</h1>

      <div class="space-y-4">
        <%!-- Schedules card --%>
        <div class="border-2 border-gray-200 rounded-xl overflow-hidden">
          <div class="px-4 py-3 bg-gray-50 border-b border-gray-200">
            <span class="text-xs font-semibold uppercase tracking-widest text-gray-500">Schedules</span>
          </div>
          <div class="divide-y divide-gray-100">
            <div class="px-4 py-4 flex items-center justify-between">
              <div>
                <p class="text-sm font-medium text-gray-800">Upload a New Schedule</p>
                <p class="text-xs text-gray-500 mt-0.5">Import a CSV to create a new academic year schedule.</p>
              </div>
              <.link
                navigate="/admin/upload"
                class="px-4 py-2 bg-blue-600 text-white text-sm font-medium rounded-lg hover:bg-blue-700 transition-colors shrink-0 ml-4"
              >
                Upload CSV
              </.link>
            </div>

            <%= if @schedules != [] do %>
              <div class="px-4 py-4">
                <div class="flex items-center justify-between mb-3">
                  <div>
                    <p class="text-sm font-medium text-gray-800">Delete a Schedule</p>
                    <p class="text-xs text-gray-500 mt-0.5">
                      Permanently removes the schedule and all associated resident and rotation data.
                    </p>
                  </div>
                  <span class="text-xs text-gray-400 ml-4 shrink-0">
                    <%= length(@schedules) %> schedule<%= if length(@schedules) != 1, do: "s" %>
                  </span>
                </div>
                <ul class="space-y-2">
                  <%= for s <- @schedules do %>
                    <li class="flex items-center justify-between rounded-lg border border-gray-200 px-3 py-2 bg-white">
                      <span class="text-sm font-medium text-gray-700"><%= s.label %></span>
                      <%= if @delete_confirm_id == s.id do %>
                        <div class="flex items-center gap-2">
                          <span class="text-xs text-red-700 font-medium">Delete <%= s.label %>?</span>
                          <button
                            phx-click="confirm_delete"
                            phx-value-id={s.id}
                            class="px-3 py-1 bg-red-600 text-white text-xs font-medium rounded-md hover:bg-red-700 transition-colors"
                          >
                            Confirm
                          </button>
                          <button
                            phx-click="cancel_delete"
                            class="px-3 py-1 bg-gray-100 text-gray-700 text-xs font-medium rounded-md hover:bg-gray-200 transition-colors"
                          >
                            Cancel
                          </button>
                        </div>
                      <% else %>
                        <button
                          phx-click="request_delete"
                          phx-value-id={s.id}
                          class="px-3 py-1 text-xs font-medium text-red-600 border border-red-200 rounded-md hover:bg-red-50 transition-colors"
                        >
                          Delete
                        </button>
                      <% end %>
                    </li>
                  <% end %>
                </ul>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Override card --%>
        <div class="border-2 border-gray-200 rounded-xl overflow-hidden">
          <div class="px-4 py-3 bg-gray-50 border-b border-gray-200">
            <span class="text-xs font-semibold uppercase tracking-widest text-gray-500">Schedule Overrides</span>
          </div>

          <div class="px-4 py-4 space-y-4">
            <div>
              <p class="text-sm font-medium text-gray-800 mb-0.5">Create a Shift Override</p>
              <p class="text-xs text-gray-500">
                Assign a resident to cover another's shift for a specific date range.
              </p>
            </div>

            <form phx-change="override_change" phx-submit="save_override" class="space-y-3">
              <%!-- Step 1: shift type + date range --%>
              <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
                <div>
                  <label class="block text-xs font-medium text-gray-600 mb-1">Shift type</label>
                  <select
                    name="rotation_type"
                    class="w-full rounded-md border border-gray-300 bg-white px-3 py-1.5 text-sm text-gray-700 focus:border-blue-500 focus:outline-none"
                  >
                    <option value="">— select —</option>
                    <%= for type <- Rotations.all_rotation_types() |> Enum.sort() do %>
                      <option value={type} selected={@override_rotation_type == type}>
                        <%= Rotations.rotation_type_label(type) %>
                      </option>
                    <% end %>
                  </select>
                </div>

                <div>
                  <label class="block text-xs font-medium text-gray-600 mb-1">From</label>
                  <input
                    type="date"
                    name="start_date"
                    value={date_value(@override_start_date)}
                    class="w-full rounded-md border border-gray-300 bg-white px-3 py-1.5 text-sm text-gray-700 focus:border-blue-500 focus:outline-none"
                  />
                </div>

                <div>
                  <label class="block text-xs font-medium text-gray-600 mb-1">To</label>
                  <input
                    type="date"
                    name="end_date"
                    value={date_value(@override_end_date)}
                    class="w-full rounded-md border border-gray-300 bg-white px-3 py-1.5 text-sm text-gray-700 focus:border-blue-500 focus:outline-none"
                  />
                </div>
              </div>

              <%!-- Step 2: select which rotation to override --%>
              <div class={if @available_rotations == [], do: "opacity-40 pointer-events-none", else: ""}>
                <label class="block text-xs font-medium text-gray-600 mb-1">
                  Resident to cover for
                  <%= if @available_rotations == [] do %>
                    <span class="text-gray-400 font-normal">(select shift type and dates first)</span>
                  <% end %>
                </label>
                <select
                  name="rotation_id"
                  class="w-full rounded-md border border-gray-300 bg-white px-3 py-1.5 text-sm text-gray-700 focus:border-blue-500 focus:outline-none"
                >
                  <option value="">— select resident —</option>
                  <%= for rot <- @available_rotations do %>
                    <option value={rot.id} selected={to_string(rot.id) == to_string(@override_rotation_id)}>
                      <%= rot.schedule_resident.name %> (<%= rot.schedule_resident.position_code %>) — <%= Calendar.strftime(rot.start_date, "%b %-d") %> – <%= Calendar.strftime(rot.end_date, "%b %-d, %Y") %>
                    </option>
                  <% end %>
                </select>
              </div>

              <%!-- Step 3: select covering resident --%>
              <div class={if @override_rotation_id in [nil, ""], do: "opacity-40 pointer-events-none", else: ""}>
                <label class="block text-xs font-medium text-gray-600 mb-1">
                  Covering resident
                  <%= if @override_rotation_id in [nil, ""] do %>
                    <span class="text-gray-400 font-normal">(select resident to cover for first)</span>
                  <% end %>
                </label>
                <select
                  name="covering_resident_id"
                  class="w-full rounded-md border border-gray-300 bg-white px-3 py-1.5 text-sm text-gray-700 focus:border-blue-500 focus:outline-none"
                >
                  <option value="">— select covering resident —</option>
                  <%= for res <- @available_covering_residents do %>
                    <option
                      value={res.id}
                      selected={to_string(res.id) == to_string(@override_covering_resident_id)}
                    >
                      <%= res.name %> (<%= res.position_code %>)
                    </option>
                  <% end %>
                </select>
              </div>

              <%= if @override_error do %>
                <p class="text-sm text-red-600"><%= @override_error %></p>
              <% end %>
              <%= if @override_success do %>
                <p class="text-sm text-green-600"><%= @override_success %></p>
              <% end %>

              <button
                type="submit"
                class="px-4 py-2 bg-blue-600 text-white text-sm font-medium rounded-lg hover:bg-blue-700 transition-colors"
              >
                Save Override
              </button>
            </form>
          </div>

          <%!-- Existing overrides list --%>
          <%= if @existing_overrides != [] do %>
            <div class="border-t border-gray-200">
              <div class="px-4 py-3 bg-gray-50 border-b border-gray-100">
                <span class="text-xs font-semibold uppercase tracking-widest text-gray-500">
                  Active Overrides (<%= length(@existing_overrides) %>)
                </span>
              </div>
              <ul class="divide-y divide-gray-100">
                <%= for o <- @existing_overrides do %>
                  <li class="px-4 py-3 flex items-start justify-between gap-3">
                    <div class="text-sm text-gray-700 leading-snug">
                      <span class={"inline-block rounded px-1.5 py-0.5 text-xs font-medium mr-1 #{Rotations.rotation_type_color(o.rotation.rotation_type)}"}>
                        <%= Rotations.rotation_type_label(o.rotation.rotation_type) %>
                      </span>
                      <span class="font-medium"><%= o.rotation.schedule_resident.name %></span>
                      <span class="text-gray-400 mx-1">covered by</span>
                      <span class="font-medium"><%= o.covering_schedule_resident.name %></span>
                      <span class="text-gray-400 text-xs ml-1">
                        <%= Calendar.strftime(o.override_start_date, "%b %-d") %>–<%= Calendar.strftime(o.override_end_date, "%b %-d, %Y") %>
                      </span>
                    </div>
                    <button
                      phx-click="delete_override"
                      phx-value-id={o.id}
                      class="text-xs text-red-500 hover:text-red-700 shrink-0 mt-0.5"
                    >
                      Remove
                    </button>
                  </li>
                <% end %>
              </ul>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp date_value(nil), do: ""
  defp date_value(%Date{} = d), do: Date.to_iso8601(d)
  defp date_value(_), do: ""
end
