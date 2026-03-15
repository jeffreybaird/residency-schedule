defmodule ResidencyScheduleWeb.AdminLive.Index do
  use ResidencyScheduleWeb, :live_view

  alias ResidencySchedule.Schedules

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       schedules: Schedules.list_schedules(),
       delete_confirm_id: nil
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
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto py-10 px-4">
      <h1 class="text-2xl font-bold text-gray-800 mb-8">Admin</h1>

      <div class="space-y-4">
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
                title="Go to the CSV upload page"
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
                            title="Confirm deletion of #{s.label}"
                          >
                            Confirm
                          </button>
                          <button
                            phx-click="cancel_delete"
                            class="px-3 py-1 bg-gray-100 text-gray-700 text-xs font-medium rounded-md hover:bg-gray-200 transition-colors"
                            title="Cancel deletion"
                          >
                            Cancel
                          </button>
                        </div>
                      <% else %>
                        <button
                          phx-click="request_delete"
                          phx-value-id={s.id}
                          class="px-3 py-1 text-xs font-medium text-red-600 border border-red-200 rounded-md hover:bg-red-50 transition-colors"
                          title={"Delete #{s.label}"}
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
      </div>
    </div>
    """
  end
end
