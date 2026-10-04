defmodule ResidencyScheduleWeb.ActivitiesLive.Index do
  use ResidencyScheduleWeb, :live_view
  alias ResidencySchedule.{DetailedSchedules, ResidentDisplayNames, Residents, Schedules}

  @filters ~w(academic_year query start_date end_date resident_id page)

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       schedules: Schedules.list_schedules(),
       suggestions_open: false,
       active_suggestion: nil
     )}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    filters =
      params
      |> Map.take(@filters)
      |> Map.put_new("academic_year", latest_year(socket.assigns.schedules))

    {:noreply, load_search(socket, filters)}
  end

  @impl true
  def handle_event("search", params, socket) do
    filters =
      Map.merge(socket.assigns.filters, Map.take(params, @filters)) |> Map.put("page", "1")

    {:noreply,
     socket |> assign(suggestions_open: true, active_suggestion: nil) |> patch_search(filters)}
  end

  @impl true
  def handle_event("focus-suggestions", _params, socket) do
    {:noreply, assign(socket, suggestions_open: socket.assigns.suggestions != [])}
  end

  @impl true
  def handle_event("close-suggestions", _params, socket),
    do: {:noreply, close_suggestions(socket)}

  @impl true
  def handle_event("select-suggestion", params, socket),
    do: {:noreply, select_suggestion(socket, Map.get(params, "label"))}

  @impl true
  def handle_event("suggestion-key", %{"key" => key}, socket),
    do: {:noreply, apply_suggestion_key(socket, key)}

  @impl true
  def handle_event("paginate", %{"page" => page}, socket) do
    {:noreply, patch_search(socket, Map.put(socket.assigns.filters, "page", page))}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <main class="max-w-5xl mx-auto px-4 sm:px-6 py-8">
      <h1 class="text-2xl font-semibold mb-2">Activities</h1>
      <p class="text-gray-600 dark:text-gray-300 mb-6">
        Find daily assignments by resident, task or notes.
      </p>
      <.form
        for={@form}
        id="activities-search-form"
        phx-change="search"
        phx-submit="search"
        class="grid gap-4 sm:grid-cols-2 lg:grid-cols-3 mb-6"
      >
        <div class="relative" data-activity-typeahead phx-click-away="close-suggestions">
          <.input
            id="activities-query"
            field={@form[:query]}
            type="search"
            label="Search"
            placeholder="Name, clinic, task or note"
            maxlength="200"
            autocomplete="off"
            role="combobox"
            aria-autocomplete="list"
            aria-controls="activity-suggestions"
            aria-expanded={to_string(@suggestions_open)}
            aria-activedescendant={
              if @active_suggestion, do: "activity-suggestion-#{@active_suggestion}"
            }
            phx-hook="ActivityTypeahead"
            phx-focus="focus-suggestions"
            phx-debounce="300"
          />
          <div
            :if={@suggestions_open}
            id="activity-suggestions"
            role="listbox"
            aria-label="Activity suggestions"
            class="absolute top-full left-0 right-0 z-30 mt-1 max-h-64 overflow-y-auto rounded-lg border border-gray-200 dark:border-gray-600 bg-white dark:bg-gray-900 shadow-lg"
          >
            <button
              :for={{label, index} <- Enum.with_index(@suggestions)}
              id={"activity-suggestion-#{index}"}
              type="button"
              role="option"
              data-value={label}
              aria-selected={to_string(@active_suggestion == index)}
              tabindex="-1"
              phx-click="select-suggestion"
              phx-value-label={label}
              class={[
                "block w-full px-3 py-2 text-left text-sm hover:bg-blue-50 dark:hover:bg-blue-950",
                @active_suggestion == index && "bg-blue-100 dark:bg-blue-950"
              ]}
            >
              {label}
            </button>
          </div>
        </div>
        <.input
          field={@form[:academic_year]}
          type="select"
          label="Academic year"
          options={Enum.map(@schedules, &{&1.label, &1.academic_year})}
        />
        <.input
          field={@form[:resident_id]}
          type="select"
          label="Resident"
          prompt="All residents"
          options={Enum.map(@residents, &{&1.name, &1.resident_id})}
        />
        <.input field={@form[:start_date]} type="date" label="From" />
        <.input field={@form[:end_date]} type="date" label="Through" />
      </.form>

      <p
        :if={@error}
        id="activities-error"
        role="alert"
        class="rounded-lg bg-red-50 text-red-800 dark:bg-red-950 dark:text-red-200 p-4 mb-4"
      >
        {@error}
      </p>
      <p
        id="activities-summary"
        data-total={@result.total}
        class="text-sm text-gray-600 dark:text-gray-300 mb-3"
      >
        {@result.total} {if @result.total == 1, do: "activity", else: "activities"}
      </p>
      <div id="activities-results" class="space-y-3">
        <p
          :if={@result.entries == []}
          class="rounded-lg border border-gray-200 dark:border-gray-700 p-6 text-gray-500 dark:text-gray-300"
        >
          No activities found
        </p>
        <article
          :for={activity <- @result.entries}
          data-activity-id={activity.id}
          class="rounded-lg border border-gray-200 dark:border-gray-700 bg-white dark:bg-gray-900 p-4"
        >
          <div class="flex flex-wrap items-center justify-between gap-2 mb-2">
            <.link
              navigate={"/residents/#{activity.schedule_resident_id}"}
              class="font-semibold text-blue-700 dark:text-blue-300 hover:underline"
            >
              {activity.display_name}
            </.link>
            <time datetime={activity.date} class="text-sm text-gray-600 dark:text-gray-300">
              {Date.to_iso8601(activity.date)}
            </time>
          </div>
          <p class="font-medium">{activity.raw_task}</p>
          <p
            :if={activity.period || activity.site}
            class="text-sm text-gray-500 dark:text-gray-300 mt-1"
          >
            {Enum.join(Enum.reject([activity.period, activity.site], &is_nil/1), " · ")}
          </p>
          <ul
            :if={activity.notes != []}
            class="mt-2 space-y-1 text-sm text-gray-700 dark:text-gray-200"
          >
            <li :for={note <- activity.notes} class="whitespace-pre-wrap">{note}</li>
          </ul>
        </article>
      </div>
      <nav aria-label="Activity results pages" class="flex items-center justify-between gap-4 mt-6">
        <button
          :if={@result.page > 1}
          id="activities-prev-page"
          type="button"
          phx-click="paginate"
          phx-value-page={@result.page - 1}
          class="rounded-lg border border-gray-300 dark:border-gray-600 px-4 py-2 hover:bg-gray-100 dark:hover:bg-gray-800"
        >
          Previous
        </button>
        <button
          :if={@result.page * @result.page_size < @result.total}
          id="activities-next-page"
          type="button"
          phx-click="paginate"
          phx-value-page={@result.page + 1}
          class="ml-auto rounded-lg border border-gray-300 dark:border-gray-600 px-4 py-2 hover:bg-gray-100 dark:hover:bg-gray-800"
        >
          Next
        </button>
      </nav>
    </main>
    """
  end

  defp load_search(socket, filters) do
    {result, error} =
      case DetailedSchedules.search(filters) do
        {:ok, result} -> {result, nil}
        {:error, reason} -> {%{entries: [], total: 0, page: 1, page_size: 50}, reason}
      end

    display_filters = Map.new(filters, fn {key, value} -> {key, display_value(value)} end)

    suggestions = load_suggestions(filters, error)

    assign(socket,
      filters: display_filters,
      form: to_form(display_filters),
      result: result,
      suggestions: suggestions,
      suggestions_open: socket.assigns.suggestions_open and suggestions != [],
      active_suggestion: nil,
      error: error,
      residents: search_residents(socket.assigns.schedules, display_filters["academic_year"])
    )
  end

  defp load_suggestions(filters, nil) do
    case DetailedSchedules.activity_suggestions(filters) do
      {:ok, labels} -> labels
      {:error, _} -> []
    end
  end

  defp load_suggestions(_, _), do: []

  defp close_suggestions(socket),
    do: assign(socket, suggestions_open: false, active_suggestion: nil)

  defp select_suggestion(socket, value) do
    if value in socket.assigns.suggestions do
      filters = socket.assigns.filters |> Map.put("query", value) |> Map.put("page", "1")

      socket
      |> close_suggestions()
      |> push_event("activity-query-selected", %{query: value})
      |> patch_search(filters)
    else
      socket
    end
  end

  defp apply_suggestion_key(socket, "Escape"), do: close_suggestions(socket)

  defp apply_suggestion_key(
         %{assigns: %{active_suggestion: index, suggestions_open: true}} = socket,
         "Enter"
       )
       when is_integer(index),
       do: select_suggestion(socket, Enum.at(socket.assigns.suggestions, index))

  defp apply_suggestion_key(socket, key) when key in ["ArrowDown", "ArrowUp"] do
    count = length(socket.assigns.suggestions)

    if count > 0 do
      step = if key == "ArrowDown", do: 1, else: -1
      initial = if step == 1, do: -1, else: 0
      index = Integer.mod((socket.assigns.active_suggestion || initial) + step, count)
      assign(socket, suggestions_open: true, active_suggestion: index)
    else
      close_suggestions(socket)
    end
  end

  defp apply_suggestion_key(socket, _), do: socket

  defp search_residents(schedules, year) do
    case Enum.find(schedules, &(to_string(&1.academic_year) == year)) do
      nil ->
        []

      schedule ->
        schedule.id
        |> Residents.list_residents_for_schedule()
        |> ResidentDisplayNames.apply_to_schedule_residents()
    end
  end

  defp latest_year([]), do: ""

  defp latest_year(schedules),
    do: schedules |> List.last() |> Map.fetch!(:academic_year) |> to_string()

  defp display_value(value) when is_binary(value), do: value
  defp display_value(value) when is_integer(value), do: to_string(value)
  defp display_value(_), do: ""

  defp search_path(filters) do
    query =
      filters |> Map.new(fn {key, value} -> {key, display_value(value)} end) |> URI.encode_query()

    "/activities?" <> query
  end

  defp patch_search(socket, filters) do
    if Enum.all?(filters, fn {_, value} -> is_binary(value) or is_integer(value) end) do
      push_patch(socket, to: search_path(filters))
    else
      load_search(socket, filters)
    end
  end
end
