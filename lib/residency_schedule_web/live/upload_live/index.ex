defmodule ResidencyScheduleWeb.UploadLive.Index do
  use ResidencyScheduleWeb, :live_view

  on_mount {ResidencyScheduleWeb.UserAuth, :ensure_admin}

  alias ResidencySchedule.Importer.ResidentLinker
  alias ResidencySchedule.Importer.ScheduleImporter
  alias ResidencySchedule.Residents
  alias ResidencySchedule.Schedules

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(upload_result: nil, warnings: [], error: nil, review: nil)
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

  # Step 1: parse the file and propose a link for every row. Nothing is
  # written until the admin confirms the links in step 2.
  @impl true
  def handle_event("save", _params, socket) do
    result =
      consume_uploaded_entries(socket, :schedule_csv, fn %{path: path}, _entry ->
        {:ok, path |> File.read!() |> ScheduleImporter.prepare()}
      end)

    # consume_uploaded_entries unwraps {:ok, value} → returns [value]
    case result do
      [{:ok, prepared}] ->
        {:noreply,
         assign(socket, review: build_review(prepared), warnings: prepared.warnings, error: nil)}

      [{:error, reason}] ->
        {:noreply, assign(socket, error: reason, review: nil, warnings: [])}

      [] ->
        {:noreply, assign(socket, error: "Please select a CSV file.", review: nil)}

      _ ->
        {:noreply, assign(socket, error: "Unexpected error during upload.", review: nil)}
    end
  end

  # Step 2: persist with the confirmed links.
  @impl true
  def handle_event("confirm", params, socket) do
    review = socket.assigns.review
    links = ResidentLinker.links_from_params(review.proposals, Map.get(params, "link", %{}))

    case ScheduleImporter.commit(review.parsed, review.academic_year, links) do
      {:ok, %{schedule_id: schedule_id} = summary} ->
        socket =
          socket
          |> assign(upload_result: summary, error: nil)
          |> push_navigate(to: "/?schedule_id=#{schedule_id}")

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, error: reason, review: %{review | links: links})}
    end
  end

  @impl true
  def handle_event("cancel-review", _params, socket) do
    {:noreply, assign(socket, review: nil, warnings: [], error: nil)}
  end

  defp build_review(prepared) do
    proposals = prepared.proposals

    %{
      parsed: prepared.parsed,
      academic_year: prepared.academic_year,
      label: Schedules.academic_year_label(prepared.academic_year),
      replaces_existing?: Schedules.get_by_year(prepared.academic_year) != nil,
      proposals: proposals,
      people: Residents.list_residents(),
      links: ResidentLinker.links_from_params(proposals, %{})
    }
  end

  @impl true
  def render(%{review: review} = assigns) when not is_nil(review) do
    ~H"""
    <div class="max-w-4xl mx-auto py-12 px-4">
      <h1 class="text-3xl font-bold text-gray-800 mb-2">Confirm Residents</h1>
      <p class="text-gray-600 mb-6">
        {@review.label} · {length(@review.proposals)} rows.
        Each row is matched to an existing resident where possible so their record carries
        across academic years. Check every link before importing.
        <%= if @review.replaces_existing? do %>
          <span class="font-medium text-yellow-800">
            A schedule for {@review.label} already exists and will be replaced.
          </span>
        <% end %>
      </p>

      <%= if @error do %>
        <div class="rounded-md bg-red-50 border border-red-200 px-4 py-3 text-sm text-red-700 mb-4">
          {@error}
        </div>
      <% end %>

      <.form for={%{}} phx-submit="confirm" class="space-y-6">
        <table class="w-full text-sm" id="link-review">
          <thead>
            <tr class="text-left text-gray-500 border-b">
              <th class="py-2 pr-4">Row</th>
              <th class="py-2 pr-4">Name in CSV</th>
              <th class="py-2 pr-4">Match</th>
              <th class="py-2">Link to</th>
            </tr>
          </thead>
          <tbody>
            <%= for proposal <- @review.proposals do %>
              <tr class="border-b" data-row={proposal.position_code}>
                <td class="py-2 pr-4 font-mono text-gray-700">{proposal.position_code}</td>
                <td class="py-2 pr-4 text-gray-800">{proposal.name}</td>
                <td class="py-2 pr-4">
                  <span class={"px-2 py-0.5 rounded-full text-xs font-semibold #{confidence_class(proposal.confidence)}"}>
                    {confidence_label(proposal)}
                  </span>
                </td>
                <td class="py-2">
                  <select
                    name={"link[#{proposal.position_code}]"}
                    class="border border-gray-300 rounded-md text-sm px-2 py-1 w-full max-w-xs"
                  >
                    <option
                      value="new"
                      selected={Map.get(@review.links, proposal.position_code) == :new}
                    >
                      New resident: {proposal.name}
                    </option>
                    <%= for person <- @review.people do %>
                      <option
                        value={person.id}
                        selected={Map.get(@review.links, proposal.position_code) == person.id}
                      >
                        {person.name}
                      </option>
                    <% end %>
                  </select>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>

        <%= if length(@warnings) > 0 do %>
          <div class="rounded-md bg-yellow-50 border border-yellow-200 px-4 py-3">
            <p class="text-sm font-medium text-yellow-800 mb-2">
              {length(@warnings)} unrecognized abbreviation(s) will be skipped:
            </p>
            <ul class="text-sm text-yellow-700 list-disc list-inside space-y-0.5">
              <%= for {code, _idx, val} <- Enum.take(@warnings, 20) do %>
                <li>{code}: "{val}"</li>
              <% end %>
            </ul>
          </div>
        <% end %>

        <div class="flex gap-3">
          <button
            type="submit"
            class="bg-blue-600 hover:bg-blue-700 text-white font-medium py-2 px-6 rounded-md text-sm transition-colors"
          >
            Confirm and Import
          </button>
          <button
            type="button"
            phx-click="cancel-review"
            class="py-2 px-4 text-sm text-gray-600 hover:text-gray-800"
          >
            Cancel
          </button>
        </div>
      </.form>
    </div>
    """
  end

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
              <span class="text-sm text-gray-700">{entry.client_name}</span>
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
              <p class="mt-1 text-sm text-red-600">{humanize_error(err)}</p>
            <% end %>
          <% end %>
        </div>

        <%= if @error do %>
          <div class="rounded-md bg-red-50 border border-red-200 px-4 py-3 text-sm text-red-700">
            {@error}
          </div>
        <% end %>

        <%= if length(@warnings) > 0 do %>
          <div class="rounded-md bg-yellow-50 border border-yellow-200 px-4 py-3">
            <p class="text-sm font-medium text-yellow-800 mb-2">
              {length(@warnings)} unrecognized abbreviation(s) were skipped:
            </p>
            <ul class="text-sm text-yellow-700 list-disc list-inside space-y-0.5">
              <%= for {code, _idx, val} <- Enum.take(@warnings, 20) do %>
                <li>{code}: "{val}"</li>
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
          <.link navigate="/admin" class="py-2 px-4 text-sm text-gray-600 hover:text-gray-800">
            Back to Admin
          </.link>
        </div>
      </.form>
    </div>
    """
  end

  defp confidence_label(%{confidence: :exact}), do: "Exact name"
  defp confidence_label(%{confidence: :alias}), do: "Roster alias"
  defp confidence_label(%{confidence: :first_name}), do: "First name"
  defp confidence_label(%{suggestions: []}), do: "No match"
  defp confidence_label(%{suggestions: many}), do: "#{length(many)} possible matches"

  defp confidence_class(:exact), do: "bg-green-100 text-green-700"
  defp confidence_class(:alias), do: "bg-green-100 text-green-700"
  defp confidence_class(:first_name), do: "bg-yellow-100 text-yellow-800"
  defp confidence_class(:none), do: "bg-gray-100 text-gray-600"

  defp humanize_error(:too_large), do: "File is too large (max 5 MB)"
  defp humanize_error(:too_many_files), do: "Only one file at a time"
  defp humanize_error(err), do: "Upload error: #{inspect(err)}"
end
