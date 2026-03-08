defmodule ResidencyScheduleWeb.UploadLive.Index do
  use ResidencyScheduleWeb, :live_view

  alias ResidencySchedule.Importer.ScheduleImporter

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(upload_result: nil, warnings: [], error: nil)
      |> allow_upload(:schedule_csv,
        accept: :any,
        max_entries: 1,
        max_file_size: 5_000_000
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("validate", _params, socket) do
    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :schedule_csv, ref)}
  end

  @impl true
  def handle_event("save", _params, socket) do
    result =
      consume_uploaded_entries(socket, :schedule_csv, fn %{path: path}, _entry ->
        csv_binary = File.read!(path)
        {:ok, ScheduleImporter.import_csv(csv_binary)}
      end)

    # consume_uploaded_entries unwraps {:ok, value} → returns [value]
    case result do
      [{:ok, summary, warnings}] ->
        socket =
          socket
          |> assign(upload_result: summary, warnings: warnings, error: nil)
          |> push_navigate(to: "/")

        {:noreply, socket}

      [{:error, reason}] ->
        {:noreply, assign(socket, error: reason, upload_result: nil, warnings: [])}

      [] ->
        {:noreply, assign(socket, error: "Please select a CSV file.", upload_result: nil)}

      _ ->
        {:noreply, assign(socket, error: "Unexpected error during upload.", upload_result: nil)}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto py-12 px-4">
      <h1 class="text-3xl font-bold text-gray-800 mb-8">Upload Schedule</h1>

      <.form for={%{}} phx-submit="save" phx-change="validate" class="space-y-6">
        <div
          class="border-2 border-dashed border-gray-300 rounded-xl p-8 text-center hover:border-blue-400 transition-colors"
          phx-drop-target={@uploads.schedule_csv.ref}
        >
          <.live_file_input upload={@uploads.schedule_csv} class="sr-only" />

          <div class="space-y-2">
            <p class="text-gray-600">Drag and drop a CSV file here, or</p>
            <label
              for={@uploads.schedule_csv.ref}
              class="cursor-pointer inline-block bg-blue-600 text-white px-4 py-2 rounded-md text-sm font-medium hover:bg-blue-700 transition-colors"
            >
              Browse files
            </label>
          </div>

          <%= for entry <- @uploads.schedule_csv.entries do %>
            <div class="mt-4 flex items-center justify-between bg-gray-50 rounded-md px-4 py-2">
              <span class="text-sm text-gray-700"><%= entry.client_name %></span>
              <button
                type="button"
                phx-click="cancel-upload"
                phx-value-ref={entry.ref}
                class="text-red-500 hover:text-red-700 text-xs"
              >
                Remove
              </button>
            </div>
            <%= for err <- upload_errors(@uploads.schedule_csv, entry) do %>
              <p class="mt-1 text-sm text-red-600"><%= humanize_error(err) %></p>
            <% end %>
          <% end %>
        </div>

        <%= if @error do %>
          <div class="rounded-md bg-red-50 border border-red-200 px-4 py-3 text-sm text-red-700">
            <%= @error %>
          </div>
        <% end %>

        <%= if length(@warnings) > 0 do %>
          <div class="rounded-md bg-yellow-50 border border-yellow-200 px-4 py-3">
            <p class="text-sm font-medium text-yellow-800 mb-2">
              <%= length(@warnings) %> unrecognized abbreviation(s) were skipped:
            </p>
            <ul class="text-sm text-yellow-700 list-disc list-inside space-y-0.5">
              <%= for {code, _idx, val} <- Enum.take(@warnings, 20) do %>
                <li><%= code %>: "<%= val %>"</li>
              <% end %>
            </ul>
          </div>
        <% end %>

        <div class="flex gap-3">
          <button
            type="submit"
            class="bg-blue-600 hover:bg-blue-700 text-white font-medium py-2 px-6 rounded-md text-sm transition-colors"
          >
            Import Schedule
          </button>
          <.link navigate="/" class="py-2 px-4 text-sm text-gray-600 hover:text-gray-800">
            Cancel
          </.link>
        </div>
      </.form>
    </div>
    """
  end

  defp humanize_error(:too_large), do: "File is too large (max 5 MB)"
  defp humanize_error(:too_many_files), do: "Only one file at a time"
  defp humanize_error(err), do: "Upload error: #{inspect(err)}"
end
