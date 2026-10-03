defmodule ResidencyScheduleWeb.UploadLive.Index do
  use ResidencyScheduleWeb, :live_view

  on_mount {ResidencyScheduleWeb.UserAuth, :ensure_admin}

  alias ResidencySchedule.DetailedSchedules
  alias ResidencySchedule.Importer.QgendaPreview
  alias ResidencySchedule.Importer.ResidentLinker
  alias ResidencySchedule.Importer.ScheduleImporter
  alias ResidencySchedule.Residents
  alias ResidencySchedule.Schedules

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(
        upload_result: nil,
        warnings: [],
        error: nil,
        review: nil,
        import_mode: "replace_year",
        target_academic_year: "",
        schedules: Schedules.list_schedules()
      )
      |> assign(
        qgenda_preview: nil,
        qgenda_saved: nil,
        qgenda_error: nil,
        qgenda_year: "",
        qgenda_query: "",
        qgenda_page: 1,
        qgenda_rows: [],
        qgenda_count: 0
      )
      |> allow_upload(:qgenda_xlsx, accept: ~w(.xlsx), max_entries: 1, max_file_size: 5_000_000)
      |> allow_upload(:qgenda_crosswalk_csv,
        accept: ~w(.csv),
        max_entries: 1,
        max_file_size: 1_000_000
      )
      |> allow_upload(:schedule_csv,
        accept: :any,
        max_entries: 1,
        max_file_size: 5_000_000
      )

    {:ok, socket}
  end

  @impl true
  def handle_event("qgenda-validate", params, socket) do
    year = Map.get(params, "academic_year", socket.assigns.qgenda_year)

    socket =
      if year != socket.assigns.qgenda_year,
        do: assign(socket, qgenda_preview: nil, qgenda_saved: nil),
        else: socket

    {:noreply, assign(socket, qgenda_year: year)}
  end

  def handle_event("qgenda-cancel-preview", _, socket) do
    {:noreply, assign(socket, qgenda_preview: nil, qgenda_saved: nil, qgenda_error: nil)}
  end

  def handle_event("qgenda-save", _, %{assigns: %{qgenda_saved: saved}} = socket)
      when not is_nil(saved), do: {:noreply, socket}

  def handle_event("qgenda-save", _, socket) do
    case DetailedSchedules.commit(socket.assigns.qgenda_preview, socket.assigns.current_user) do
      {:ok, result} -> {:noreply, assign(socket, qgenda_saved: result, qgenda_error: nil)}
      {:error, reason} -> {:noreply, assign(socket, qgenda_error: reason)}
    end
  end

  def handle_event("qgenda-preview", params, socket) do
    socket = assign(socket, qgenda_saved: nil)
    year = parse_year(Map.get(params, "academic_year", socket.assigns.qgenda_year))

    result =
      if qgenda_uploads_ready?(socket) do
        options = qgenda_preview_options(socket, year)

        consume_uploaded_entries(socket, :qgenda_xlsx, fn %{path: path}, _ ->
          {:ok, path |> File.read!() |> QgendaPreview.prepare(options)}
        end)
      else
        [
          {:error,
           "Complete or remove rejected QGenda uploads before previewing. XLSX files must be at most 5 MB; crosswalk CSV files must be at most 1 MB."}
        ]
      end

    case result do
      [{:ok, preview}] ->
        {:noreply,
         socket
         |> assign(qgenda_preview: preview, qgenda_error: nil, qgenda_query: "", qgenda_page: 1)
         |> assign_qgenda_rows()}

      [{:error, reason}] ->
        {:noreply, assign(socket, qgenda_preview: nil, qgenda_error: reason)}

      _ ->
        {:noreply,
         assign(socket, qgenda_preview: nil, qgenda_error: "Select a QGenda XLSX workbook.")}
    end
  end

  def handle_event("qgenda-filter", %{"query" => query}, socket) do
    {:noreply,
     socket
     |> assign(qgenda_query: String.slice(query, 0, 200), qgenda_page: 1)
     |> assign_qgenda_rows()}
  end

  def handle_event("qgenda-page", %{"direction" => direction}, socket) do
    delta = if direction == "next", do: 1, else: -1
    last = max(1, ceil(socket.assigns.qgenda_count / 100))
    page = socket.assigns.qgenda_page |> Kernel.+(delta) |> max(1) |> min(last)
    {:noreply, socket |> assign(qgenda_page: page) |> assign_qgenda_rows()}
  end

  def handle_event("qgenda-cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :qgenda_xlsx, ref)}
  end

  def handle_event("qgenda-cancel-crosswalk", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :qgenda_crosswalk_csv, ref)}
  end

  def handle_event("validate", params, socket) do
    {:noreply, assign_import_options(socket, params)}
  end

  @impl true
  def handle_event("cancel-upload", %{"ref" => ref}, socket) do
    {:noreply, cancel_upload(socket, :schedule_csv, ref)}
  end

  # Step 1: parse the file and propose a link for every row. Nothing is
  # written until the admin confirms the links in step 2.
  @impl true
  def handle_event("save", params, socket) do
    socket = assign_import_options(socket, params)
    options = import_options(socket)

    result =
      consume_uploaded_entries(socket, :schedule_csv, fn %{path: path}, _entry ->
        {:ok, path |> File.read!() |> ScheduleImporter.prepare(options)}
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
  def handle_event("confirm", _params, %{assigns: %{review: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("confirm", params, socket) do
    review = socket.assigns.review

    links =
      if review.mode == :update_dates,
        do: review.links,
        else: ResidentLinker.links_from_params(review.proposals, Map.get(params, "link", %{}))

    case ScheduleImporter.commit(review.parsed, review.academic_year, links, mode: review.mode) do
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
      mode: Map.get(prepared, :mode, :replace_year),
      date_range: Map.get(prepared, :date_range),
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
      <h1 class="text-3xl font-bold text-gray-800 dark:text-gray-100 mb-2">Confirm Residents</h1>
      <%= if @review.mode == :update_dates do %>
        <div
          id="date-update-review"
          class="rounded-md bg-blue-50 dark:bg-blue-950 px-4 py-3 mb-6 text-blue-900 dark:text-blue-300"
        >
          <p class="font-medium">Update dates in {@review.label}</p>
          <p>
            {elem(@review.date_range, 0)} through {elem(@review.date_range, 1)} · {length(
              @review.proposals
            )} residents.
          </p>
          <p>Assignments on other dates and residents not in this file are preserved.
            OFF clears an assignment. Blank and unrecognized cells are preserved.</p>
          <p>
            Existing resident links are locked. Rotations with coverage requests or overrides cannot be changed.
          </p>
        </div>
      <% else %>
        <p class="text-gray-600 dark:text-gray-300 mb-6">
          {@review.label} · {length(@review.proposals)} rows.
          Each row is matched to an existing resident where possible so their record carries
          across academic years. Check every link before importing.
          <%= if @review.replaces_existing? do %>
            <span class="font-medium text-yellow-800 dark:text-yellow-300">
              A schedule for {@review.label} already exists and will be replaced.
            </span>
          <% end %>
        </p>
      <% end %>

      <%= if @error do %>
        <div class="rounded-md bg-red-50 dark:bg-red-950 border border-red-200 dark:border-red-800 px-4 py-3 text-sm text-red-700 dark:text-red-300 mb-4">
          {@error}
        </div>
      <% end %>

      <.form for={%{}} phx-submit="confirm" class="space-y-6">
        <table class="w-full text-sm" id="link-review">
          <thead>
            <tr class="text-left text-gray-500 dark:text-gray-300 border-b">
              <th class="py-2 pr-4">Row</th>
              <th class="py-2 pr-4">Name in CSV</th>
              <th class="py-2 pr-4">Match</th>
              <th class="py-2">Link to</th>
            </tr>
          </thead>
          <tbody>
            <%= for proposal <- @review.proposals do %>
              <tr class="border-b" data-row={proposal.position_code}>
                <td class="py-2 pr-4 font-mono text-gray-700 dark:text-gray-200">
                  {proposal.position_code}
                </td>
                <td class="py-2 pr-4 text-gray-800 dark:text-gray-100">{proposal.name}</td>
                <td class="py-2 pr-4">
                  <span class={"px-2 py-0.5 rounded-full text-xs font-semibold #{confidence_class(proposal.confidence)}"}>
                    {confidence_label(proposal)}
                  </span>
                </td>
                <td class="py-2">
                  <%= if @review.mode == :update_dates do %>
                    <span class="text-gray-700 dark:text-gray-200">
                      {proposal.name} (existing resident)
                    </span>
                  <% else %>
                    <select
                      name={"link[#{proposal.position_code}]"}
                      class="border border-gray-300 dark:border-gray-600 rounded-md text-sm px-2 py-1 w-full max-w-xs"
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
                  <% end %>
                </td>
              </tr>
            <% end %>
          </tbody>
        </table>

        <%= if length(@warnings) > 0 do %>
          <div class="rounded-md bg-yellow-50 dark:bg-yellow-950 border border-yellow-200 dark:border-yellow-800 px-4 py-3">
            <p class="text-sm font-medium text-yellow-800 dark:text-yellow-300 mb-2">
              {length(@warnings)} unrecognized abbreviation(s). {if @review.mode == :update_dates,
                do: "Existing assignments on those dates will be preserved:",
                else: "These assignments will be skipped:"}
            </p>
            <ul class="text-sm text-yellow-700 dark:text-yellow-300 list-disc list-inside space-y-0.5">
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
            class="py-2 px-4 text-sm text-gray-600 dark:text-gray-300 hover:text-gray-800 dark:hover:text-gray-100"
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
      <h1 class="text-3xl font-bold text-gray-800 dark:text-gray-100 mb-8">Upload Schedule</h1>

      <.form for={%{}} phx-submit="save" phx-change="validate" class="space-y-6">
        <.input
          type="select"
          id="import-mode"
          name="mode"
          label="Import mode"
          value={@import_mode}
          options={[{"Replace year", "replace_year"}, {"Update dates", "update_dates"}]}
        />
        <.input
          type="select"
          id="target-academic-year"
          name="academic_year"
          label="Target academic year (for date updates)"
          value={@target_academic_year}
          prompt="Select an existing schedule"
          options={Enum.map(@schedules, &{&1.label, Integer.to_string(&1.academic_year)})}
        />
        <p class="text-sm text-gray-600 dark:text-gray-300">
          Update dates fills in FLOAT periods using a partial CSV.
          Only recognized assignments and explicit OFF cells change existing dates.
          Replace year replaces the complete schedule.
        </p>
        <div
          class="border-2 border-dashed border-gray-300 dark:border-gray-600 rounded-xl p-8 text-center hover:border-blue-400 transition-colors"
          phx-drop-target={@uploads.schedule_csv.ref}
        >
          <.live_file_input upload={@uploads.schedule_csv} class="sr-only" />

          <div class="space-y-2">
            <p class="text-gray-600 dark:text-gray-300">Drag and drop a CSV file here, or</p>
            <label
              for={@uploads.schedule_csv.ref}
              class="cursor-pointer inline-block bg-blue-600 text-white px-4 py-2 rounded-md text-sm font-medium hover:bg-blue-700 transition-colors"
            >
              Browse files
            </label>
          </div>

          <%= for entry <- @uploads.schedule_csv.entries do %>
            <div class="mt-4 flex items-center justify-between bg-gray-50 dark:bg-gray-950 rounded-md px-4 py-2">
              <span class="text-sm text-gray-700 dark:text-gray-200">{entry.client_name}</span>
              <button
                type="button"
                phx-click="cancel-upload"
                phx-value-ref={entry.ref}
                class="text-red-500 dark:text-red-300 hover:text-red-700 dark:hover:text-red-300 text-xs"
              >
                Remove
              </button>
            </div>
            <%= for err <- upload_errors(@uploads.schedule_csv, entry) do %>
              <p class="mt-1 text-sm text-red-600 dark:text-red-300">{humanize_error(err)}</p>
            <% end %>
          <% end %>
        </div>

        <%= if @error do %>
          <div class="rounded-md bg-red-50 dark:bg-red-950 border border-red-200 dark:border-red-800 px-4 py-3 text-sm text-red-700 dark:text-red-300">
            {@error}
          </div>
        <% end %>

        <%= if length(@warnings) > 0 do %>
          <div class="rounded-md bg-yellow-50 dark:bg-yellow-950 border border-yellow-200 dark:border-yellow-800 px-4 py-3">
            <p class="text-sm font-medium text-yellow-800 dark:text-yellow-300 mb-2">
              {length(@warnings)} unrecognized abbreviation(s) were skipped:
            </p>
            <ul class="text-sm text-yellow-700 dark:text-yellow-300 list-disc list-inside space-y-0.5">
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
          <.link
            navigate="/admin"
            class="py-2 px-4 text-sm text-gray-600 dark:text-gray-300 hover:text-gray-800 dark:hover:text-gray-100"
          >
            Back to Admin
          </.link>
        </div>
      </.form>
      <.qgenda_panel
        uploads={@uploads}
        schedules={@schedules}
        qgenda_year={@qgenda_year}
        qgenda_error={@qgenda_error}
        qgenda_preview={@qgenda_preview}
        qgenda_saved={@qgenda_saved}
        qgenda_query={@qgenda_query}
        qgenda_rows={@qgenda_rows}
        qgenda_count={@qgenda_count}
        qgenda_page={@qgenda_page}
      />
    </div>
    """
  end

  defp qgenda_panel(assigns) do
    ~H"""
    <section class="mt-12 border-t border-gray-200 dark:border-gray-700 pt-8">
      <h2 class="text-2xl font-bold mb-2">QGenda detail preview</h2>
      <p class="text-sm text-gray-600 dark:text-gray-300 mb-6">
        Review a Calendar By Staff XLSX export against an existing schedule. Detailed assignments are saved only after you confirm below; resident names and base rotations remain unchanged.
      </p>
      <.form
        for={%{}}
        id="qgenda-upload-form"
        phx-change="qgenda-validate"
        phx-submit="qgenda-preview"
        class="space-y-4"
      >
        <.input
          type="select"
          name="academic_year"
          id="qgenda-academic-year"
          label="Academic year"
          value={@qgenda_year}
          prompt="Select an existing schedule"
          options={Enum.map(@schedules, &{&1.label, Integer.to_string(&1.academic_year)})}
        />
        <.live_file_input upload={@uploads.qgenda_xlsx} />
        <div :for={entry <- @uploads.qgenda_xlsx.entries} class="text-sm">
          {entry.client_name}
          <button
            type="button"
            phx-click="qgenda-cancel-upload"
            phx-value-ref={entry.ref}
            class="ml-2 underline"
          >
            Remove
          </button>
          <p :for={error <- upload_errors(@uploads.qgenda_xlsx, entry)} class="text-red-600">
            {humanize_error(error)}
          </p>
        </div>
        <div
          id="qgenda-crosswalk-help"
          class="rounded-md bg-gray-50 dark:bg-gray-900 p-4 text-sm space-y-2"
        >
          <p class="font-semibold">Optional reviewed name crosswalk (CSV, up to 1 MB)</p>
          <p>
            If existing resident names differ from QGenda, upload the reviewed mapping alongside this workbook. It applies only to this preview. Without it, the configured crosswalk is used when available; otherwise only unambiguous full names match.
          </p>
          <p>
            Required columns: <code>academic_year,position_code,qgenda_staff,existing_name</code>. Use the selected academic year, the current roster position and exact existing name. Quote QGenda names containing commas. Each staff identity and position must occur once.
          </p>
          <.live_file_input upload={@uploads.qgenda_crosswalk_csv} />
          <div :for={entry <- @uploads.qgenda_crosswalk_csv.entries}>
            {entry.client_name}
            <button
              type="button"
              phx-click="qgenda-cancel-crosswalk"
              phx-value-ref={entry.ref}
              class="ml-2 underline"
            >
              Remove
            </button>
            <p
              :for={error <- upload_errors(@uploads.qgenda_crosswalk_csv, entry)}
              class="text-red-600"
            >
              {if error == :too_large,
                do: "Crosswalk is too large (max 1 MB)",
                else: humanize_error(error)}
            </p>
          </div>
        </div>
        <button type="submit" class="bg-blue-600 hover:bg-blue-700 text-white rounded-md px-4 py-2">
          Preview QGenda detail
        </button>
      </.form>
      <p
        :if={@qgenda_error}
        id="qgenda-error"
        role="alert"
        class="mt-4 text-red-700 dark:text-red-300"
      >
        {@qgenda_error}
      </p>
      <div :if={@qgenda_preview} id="qgenda-preview" class="mt-8 space-y-6">
        <div id="qgenda-summary" class="rounded-lg bg-blue-50 dark:bg-blue-950 p-4">
          <h3 class="font-semibold">
            {if @qgenda_saved,
              do: "Detailed assignments saved",
              else: "Preview — review before saving"}
          </h3>
          <p id="qgenda-crosswalk-source">
            Name crosswalk: {qgenda_crosswalk_source(@qgenda_preview.crosswalk_source)}
          </p>
          <p>
            {length(@qgenda_preview.assignments)} assignments · {Enum.count(
              @qgenda_preview.assignments,
              & &1.resident_id
            )} matched · {Enum.count(@qgenda_preview.assignments, &is_nil(&1.resident_id))} held without a resident match
          </p>
          <p>
            {@qgenda_preview.matches
            |> Enum.reject(&is_nil(&1.resident_id))
            |> Enum.uniq_by(& &1.resident_id)
            |> length()} residents matched · {length(@qgenda_preview.missing_residents)} missing
          </p>
          <p :for={warning <- @qgenda_preview.warnings}>{warning}</p>
        </div>
        <div id="qgenda-coverage">
          <h3 class="font-semibold">Date coverage</h3>
          <p>Workbook headers: {format_qgenda_range(@qgenda_preview.header_range)}</p>
          <p>Matched resident assignments: {format_qgenda_range(@qgenda_preview.resident_range)}</p>
          <p>
            {length(@qgenda_preview.uncovered_dates)} header dates have no matched resident detail. Missing detail does not mean availability; existing schedules remain untouched.
          </p>
          <details :if={@qgenda_preview.uncovered_dates != []}>
            <summary class="cursor-pointer underline">Show dates without resident detail</summary>
            <p>{Enum.map_join(@qgenda_preview.uncovered_dates, ", ", &Date.to_iso8601/1)}</p>
          </details>
        </div>
        <div id="qgenda-missing-residents">
          <h3 class="font-semibold">Residents missing from this export</h3>
          <p :if={@qgenda_preview.missing_residents == []}>None</p>
          <p :for={resident <- @qgenda_preview.missing_residents}>
            {resident.name} ({resident.position_code}) — preserve existing schedule
          </p>
        </div>
        <details id="qgenda-matches">
          <summary class="font-semibold cursor-pointer">Resident matching and naming</summary>
          <p :for={match <- @qgenda_preview.matches} class="text-sm py-1">
            {if match.display_name == "", do: "Blank staff", else: match.display_name} — {match.status}
            <span :if={match.previous_name}>
              · Existing name / retained alias: {match.previous_name}
            </span>
          </p>
        </details>
        <div id="qgenda-unknown-tasks">
          <h3 class="font-semibold">Unrecognized task labels</h3>
          <p :if={@qgenda_preview.unknown_tasks == []}>None</p>
          <p :for={task <- @qgenda_preview.unknown_tasks}>{task}</p>
          <p class="text-sm">
            All labels are preserved verbatim. No rotation or availability rules are applied.
          </p>
        </div>
        <details :if={@qgenda_preview.unlinked_notes != []} id="qgenda-unlinked-notes">
          <summary class="font-semibold cursor-pointer">
            {length(@qgenda_preview.unlinked_notes)} notes could not be linked
          </summary>
          <p :for={note <- @qgenda_preview.unlinked_notes}>
            {note.text} — {note.source_sheet}!{note.source_cell}
          </p>
        </details>
        <.form for={%{}} id="qgenda-filter-form" phx-change="qgenda-filter">
          <.input
            name="query"
            id="qgenda-query"
            value={@qgenda_query}
            label="Filter preview by person, task, date, or note"
            phx-debounce="200"
          />
        </.form>
        <p class="text-sm">
          {@qgenda_count} matching assignments · Page {@qgenda_page} of {max(
            1,
            ceil(@qgenda_count / 100)
          )}
        </p>
        <div class="overflow-x-auto">
          <table id="qgenda-assignments" class="w-full text-sm text-left">
            <thead>
              <tr>
                <th class="p-2">Date / resident</th>
                <th class="p-2">Task and notes</th>
                <th class="p-2">Source</th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={assignment <- @qgenda_rows}
                data-qgenda-assignment="true"
                data-source-cell={assignment.source_cell}
                class="border-t align-top"
              >
                <td class="p-2">
                  {assignment.date}<br />{if assignment.display_name == "",
                    do: "Blank staff",
                    else: assignment.display_name}<br />
                  <span class="text-xs">
                    {assignment.status}
                  </span>
                  <span :if={assignment.previous_name} class="block text-xs">
                    Existing name / alias: {assignment.previous_name}
                  </span>
                </td>
                <td class="p-2">
                  {assignment.raw_task}<p
                    :for={note <- assignment.notes}
                    class="mt-1 text-gray-600 dark:text-gray-300"
                  >{note}</p>
                </td>
                <td class="p-2">
                  {assignment.source_sheet}!{assignment.source_cell}<br />{assignment.raw_staff}
                  <span
                    :for={note <- qgenda_assignment_notes(@qgenda_preview.notes, assignment)}
                    class="block text-xs"
                  >
                    Note: {note.source_sheet}!{note.source_cell}
                  </span>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
        <div class="flex gap-4">
          <button
            id="qgenda-previous-page"
            type="button"
            phx-click="qgenda-page"
            phx-value-direction="previous"
            disabled={@qgenda_page == 1}
            class="btn btn-sm"
          >
            Previous
          </button>
          <button
            id="qgenda-next-page"
            type="button"
            phx-click="qgenda-page"
            phx-value-direction="next"
            disabled={@qgenda_page * 100 >= @qgenda_count}
            class="btn btn-sm"
          >
            Next
          </button>
        </div>
        <div class="rounded-lg border border-blue-200 dark:border-blue-800 p-4 space-y-3">
          <p>
            Save matched assignments alongside existing rotations. Unmatched staff are skipped. Repeated tasks are deduplicated; missing dates and older details are preserved. Corrections and removals require separate review.
          </p>
          <button
            id="qgenda-save-preview"
            type="button"
            phx-click="qgenda-save"
            disabled={not is_nil(@qgenda_saved)}
            class="btn btn-primary"
          >
            Save detailed assignments
          </button>
          <button
            id="qgenda-cancel-preview"
            type="button"
            phx-click="qgenda-cancel-preview"
            class="btn"
          >
            Close preview
          </button>
          <p :if={@qgenda_saved} id="qgenda-save-result" role="status">
            {@qgenda_saved.inserted} new assignments saved; {@qgenda_saved.existing} already present; {@qgenda_saved.skipped} unmatched assignments skipped.
          </p>
        </div>
      </div>
    </section>
    """
  end

  defp qgenda_assignment_notes(notes, assignment) do
    key = {assignment.date, assignment.raw_staff, assignment.raw_task}
    Enum.filter(notes, &(&1.assignment_key == key))
  end

  defp qgenda_preview_options(socket, year) do
    case consume_uploaded_entries(socket, :qgenda_crosswalk_csv, fn %{path: path}, _ ->
           {:ok, File.read!(path)}
         end) do
      [csv] -> [academic_year: year, crosswalk_csv: csv]
      [] -> [academic_year: year]
    end
  end

  defp qgenda_uploads_ready?(socket) do
    Enum.all?([:qgenda_xlsx, :qgenda_crosswalk_csv], fn key ->
      upload = socket.assigns.uploads[key]

      upload_errors(upload) == [] and
        Enum.all?(upload.entries, &(&1.done? and upload_errors(upload, &1) == []))
    end)
  end

  defp qgenda_crosswalk_source(:uploaded), do: "Uploaded for this preview"
  defp qgenda_crosswalk_source(:configured), do: "Configured"
  defp qgenda_crosswalk_source(:unavailable), do: "Unavailable — full-name matches only"

  defp format_qgenda_range(nil), do: "No matched assignments"
  defp format_qgenda_range({first, last}), do: "#{first} through #{last}"

  defp assign_qgenda_rows(%{assigns: %{qgenda_preview: nil}} = socket), do: socket

  defp assign_qgenda_rows(socket) do
    query = String.downcase(socket.assigns.qgenda_query)

    rows =
      Enum.filter(socket.assigns.qgenda_preview.assignments, fn row ->
        [
          row.display_name,
          row.previous_name || "",
          row.raw_staff,
          row.raw_task,
          Date.to_iso8601(row.date) | row.notes
        ]
        |> Enum.join(" ")
        |> String.downcase()
        |> String.contains?(query)
      end)

    assign(socket,
      qgenda_count: length(rows),
      qgenda_rows: Enum.slice(rows, (socket.assigns.qgenda_page - 1) * 100, 100)
    )
  end

  defp assign_import_options(socket, params) do
    assign(socket,
      import_mode: Map.get(params, "mode", socket.assigns.import_mode),
      target_academic_year: Map.get(params, "academic_year", socket.assigns.target_academic_year)
    )
  end

  defp import_options(socket) do
    case socket.assigns.import_mode do
      "update_dates" ->
        [mode: :update_dates, academic_year: parse_year(socket.assigns.target_academic_year)]

      "replace_year" ->
        [mode: :replace_year]

      _ ->
        [mode: :invalid]
    end
  end

  defp parse_year(value) when is_binary(value) do
    case Integer.parse(value) do
      {year, ""} -> year
      _ -> nil
    end
  end

  defp parse_year(_value), do: nil

  defp confidence_label(%{confidence: :exact}), do: "Exact name"
  defp confidence_label(%{confidence: :alias}), do: "Roster alias"
  defp confidence_label(%{confidence: :first_name}), do: "First name"
  defp confidence_label(%{suggestions: []}), do: "No match"
  defp confidence_label(%{suggestions: many}), do: "#{length(many)} possible matches"

  defp confidence_class(:exact),
    do: "bg-green-100 dark:bg-green-900 text-green-700 dark:text-green-300"

  defp confidence_class(:alias),
    do: "bg-green-100 dark:bg-green-900 text-green-700 dark:text-green-300"

  defp confidence_class(:first_name),
    do: "bg-yellow-100 dark:bg-yellow-900 text-yellow-800 dark:text-yellow-300"

  defp confidence_class(:none),
    do: "bg-gray-100 dark:bg-gray-800 text-gray-600 dark:text-gray-300"

  defp humanize_error(:too_large), do: "File is too large (max 5 MB)"
  defp humanize_error(:too_many_files), do: "Only one file at a time"
  defp humanize_error(err), do: "Upload error: #{inspect(err)}"
end
