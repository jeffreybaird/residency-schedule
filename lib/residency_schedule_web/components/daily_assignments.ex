defmodule ResidencyScheduleWeb.DailyAssignments do
  @moduledoc "Resident-facing daily commitments, shared by schedule detail views."
  use Phoenix.Component

  attr :id, :string, required: true
  attr :activities, :list, required: true
  attr :show_dates, :boolean, default: true

  @doc """
  Renders literal assignments and notes grouped by date.

      iex> assigns = %{__changed__: nil, id: "daily", show_dates: true, activities: [%{date: ~D[2026-12-29], raw_task: "Clinic PM", notes: ["Bring simulation kit"]}]}
      iex> match?(%Phoenix.LiveView.Rendered{}, ResidencyScheduleWeb.DailyAssignments.activities(assigns))
      true
  """
  def activities(assigns) do
    groups = assigns.activities |> Enum.group_by(& &1.date) |> Enum.sort_by(&elem(&1, 0), Date)
    assigns = assign(assigns, :groups, groups)

    ~H"""
    <div id={@id} class="space-y-3 text-sm">
      <p :if={@groups == []} class="text-gray-500 dark:text-gray-300">
        No daily assignments recorded
      </p>
      <section
        :for={{date, activities} <- @groups}
        data-date={Date.to_iso8601(date)}
        class="space-y-2"
      >
        <h4 :if={@show_dates} class="font-medium text-gray-700 dark:text-gray-200">
          {Calendar.strftime(date, "%A, %b %-d, %Y")}
        </h4>
        <ul class="space-y-2">
          <li :for={activity <- activities} class="rounded-md bg-gray-50 dark:bg-gray-900 px-3 py-2">
            <p class="font-medium">{activity.raw_task}</p>
            <p :for={note <- activity.notes} class="mt-1 text-gray-600 dark:text-gray-300">{note}</p>
          </li>
        </ul>
      </section>
    </div>
    """
  end
end
