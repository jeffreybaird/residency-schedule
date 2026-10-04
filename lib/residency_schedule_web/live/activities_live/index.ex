defmodule ResidencyScheduleWeb.ActivitiesLive.Index do
  use ResidencyScheduleWeb, :live_view
  alias ResidencySchedule.{DetailedSchedules, ResidentDisplayNames, Residents, Schedules}

  @filters ~w(academic_year query start_date end_date resident_id page)

  @impl true
  def mount(_params, _session, socket) do
    {:ok, assign(socket, schedules: Schedules.list_schedules())}
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

    {:noreply, patch_search(socket, filters)}
  end

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
        <.input
          field={@form[:query]}
          type="search"
          label="Search"
          placeholder="Name, clinic, task or note"
          maxlength="200"
          phx-debounce="300"
        />
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

    assign(socket,
      filters: display_filters,
      form: to_form(display_filters),
      result: result,
      error: error,
      residents: search_residents(socket.assigns.schedules, display_filters["academic_year"])
    )
  end

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
