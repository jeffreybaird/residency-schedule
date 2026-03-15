defmodule ResidencyScheduleWeb.AdminLive.Index do
  use ResidencyScheduleWeb, :live_view

  alias ResidencySchedule.Schedules

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, schedules: Schedules.list_schedules())}
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
              >
                Upload CSV
              </.link>
            </div>
            <div class="px-4 py-4 flex items-center justify-between">
              <div>
                <p class="text-sm font-medium text-gray-800">Delete a Schedule</p>
                <p class="text-xs text-gray-500 mt-0.5">
                  Use the <span class="font-mono text-gray-700">×</span> button next to a schedule on the
                  <.link navigate="/" class="text-blue-600 hover:underline">Schedule page</.link>.
                </p>
              </div>
              <%= if @schedules != [] do %>
                <span class="text-xs text-gray-400 ml-4 shrink-0">
                  <%= length(@schedules) %> schedule<%= if length(@schedules) != 1, do: "s" %>
                </span>
              <% end %>
            </div>
          </div>
        </div>
      </div>
    </div>
    """
  end
end
