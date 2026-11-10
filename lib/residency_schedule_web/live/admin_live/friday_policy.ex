defmodule ResidencyScheduleWeb.AdminLive.FridayPolicy do
  use ResidencyScheduleWeb, :live_view

  on_mount {ResidencyScheduleWeb.UserAuth, :ensure_admin}

  alias ResidencySchedule.TaskMappings.FridayEnrichmentRunner

  @topic "maintenance:friday-policy"

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(ResidencySchedule.PubSub, @topic)

    socket =
      socket
      |> assign(:maintenance, %{run: nil, preview: nil, last_run: nil})
      |> assign(:preview_pending, false)
      |> assign(:maintenance_error, nil)
      |> refresh()

    {:ok, socket}
  end

  @impl true
  def handle_event("preview", _params, socket) do
    case FridayEnrichmentRunner.status(socket.assigns.current_user) do
      {:ok, _status} ->
        user = socket.assigns.current_user

        {:noreply,
         socket
         |> assign(preview_pending: true, maintenance_error: nil)
         |> start_async(:friday_preview, fn -> FridayEnrichmentRunner.preview(user) end)}

      {:error, :forbidden} ->
        {:noreply, redirect(socket, to: "/")}
    end
  end

  def handle_event("apply", _params, socket) do
    token = get_in(socket.assigns.maintenance, [:preview, :token])

    case FridayEnrichmentRunner.start(socket.assigns.current_user, token) do
      {:ok, _run} -> {:noreply, refresh(socket, nil)}
      {:error, :forbidden} -> {:noreply, redirect(socket, to: "/")}
      {:error, reason} -> {:noreply, refresh(socket, error_message(reason))}
    end
  end

  @impl true
  def handle_async(:friday_preview, {:ok, result}, socket) do
    message =
      case result do
        {:ok, _preview} -> nil
        {:error, reason} -> error_message(reason)
      end

    {:noreply, socket |> assign(:preview_pending, false) |> refresh(message)}
  end

  def handle_async(:friday_preview, {:exit, _reason}, socket) do
    {:noreply,
     socket
     |> assign(:preview_pending, false)
     |> refresh(error_message(:run_failed))}
  end

  @impl true
  def handle_info(:friday_policy_enrichment_status_changed, socket),
    do: {:noreply, refresh(socket)}

  defp refresh(socket, message \\ nil) do
    case FridayEnrichmentRunner.status(socket.assigns.current_user) do
      {:ok, status} -> assign(socket, maintenance: status, maintenance_error: message)
      {:error, :forbidden} -> redirect(socket, to: "/")
    end
  end

  defp running?(%{run: %{status: :running}}), do: true
  defp running?(_status), do: false

  defp status_label(nil), do: "Ready to preview"
  defp status_label(%{operation: :preview, status: :running}), do: "Preview in progress"
  defp status_label(%{operation: :apply, status: :running}), do: "Enrichment in progress"
  defp status_label(%{operation: :preview, status: :completed}), do: "Preview complete"
  defp status_label(%{operation: :apply, status: :completed}), do: "Enrichment complete"
  defp status_label(%{status: :failed}), do: "Operation could not finish"

  defp timestamp(nil), do: "—"
  defp timestamp(value), do: Calendar.strftime(value, "%b %-d, %Y at %H:%M:%S UTC")

  defp count_rows(counts) do
    [
      {:scanned, "Checked"},
      {:eligible, "Eligible to enrich"},
      {:attested, "Enriched"},
      {:unchanged, "Already enriched"},
      {:protected, "Protected"},
      {:held, "Held for review"},
      {:conflicting, "Conflicting evidence"},
      {:not_applicable, "Outside this policy"}
    ]
    |> Enum.filter(fn {key, _label} -> Map.has_key?(counts, key) end)
    |> Enum.map(fn {key, label} -> {label, Map.fetch!(counts, key)} end)
  end

  defp error_message(:busy),
    do: "Another maintenance operation is running. Its status will update here."

  defp error_message(:invalid_preview),
    do: "Preview again before applying changes. Your previous selection is no longer available."

  defp error_message(:forbidden), do: "Administrator access is required."

  defp error_message(_reason),
    do:
      "The operation could not finish. Some records may already be enriched. Preview again before retrying."

  @impl true
  def render(assigns) do
    ~H"""
    <main class="mx-auto max-w-3xl px-4 py-8 sm:py-10">
      <.link
        navigate="/admin"
        class="text-sm font-medium text-blue-600 hover:underline dark:text-blue-300"
      >
        ← Back to Admin
      </.link>
      <header class="mb-6 mt-5">
        <p class="text-xs font-semibold uppercase tracking-widest text-gray-500 dark:text-gray-400">
          Schedule maintenance
        </p>
        <h1 class="mt-2 text-2xl font-bold text-gray-900 dark:text-gray-100">
          Historical Friday policy
        </h1>
        <p class="mt-3 text-sm leading-6 text-gray-600 dark:text-gray-300">
          Add reviewed Friday policy evidence to eligible historical records while preserving
          their original classifications. Preview the totals before applying changes.
        </p>
        <p class="mt-2 text-sm leading-6 text-gray-600 dark:text-gray-300">
          This prepares the updated schedule model. Today's displayed calendar stays the same.
        </p>
      </header>

      <section
        id="friday-policy-status"
        aria-live="polite"
        aria-atomic="true"
        class="rounded-xl border-2 border-gray-200 p-4 sm:p-6 dark:border-gray-700"
      >
        <h2 class="text-base font-semibold text-gray-900 dark:text-gray-100">
          {if @preview_pending, do: "Preparing preview", else: status_label(@maintenance.run)}
        </h2>
        <p class="mt-2 text-sm leading-6 text-gray-600 dark:text-gray-300">
          You can leave this page while maintenance runs. Return here to see the result.
          Only one operation can run at a time.
        </p>
        <p :if={@maintenance_error} role="alert" class="mt-3 text-sm text-red-700 dark:text-red-300">
          {@maintenance_error}
        </p>
        <p
          :if={@maintenance.run && @maintenance.run.error}
          role="alert"
          class="mt-3 text-sm text-red-700 dark:text-red-300"
        >
          {error_message(@maintenance.run.error)}
        </p>
        <div class="mt-5 flex flex-col gap-3 sm:flex-row">
          <button
            id="friday-policy-preview"
            phx-click="preview"
            disabled={@preview_pending or running?(@maintenance)}
            class="rounded-lg border border-blue-600 px-4 py-3 text-sm font-semibold text-blue-700 transition-colors hover:bg-blue-50 disabled:cursor-wait disabled:opacity-50 dark:text-blue-300 dark:hover:bg-blue-950"
          >
            Preview eligible records
          </button>
          <button
            id="friday-policy-apply"
            phx-click="apply"
            disabled={@preview_pending or running?(@maintenance) or is_nil(@maintenance.preview)}
            class="rounded-lg bg-blue-600 px-4 py-3 text-sm font-semibold text-white transition-colors hover:bg-blue-700 disabled:cursor-not-allowed disabled:opacity-50"
          >
            Apply reviewed preview
          </button>
        </div>
      </section>

      <section
        :if={@maintenance.preview}
        class="mt-6 rounded-xl bg-gray-50 p-4 sm:p-6 dark:bg-gray-900"
      >
        <h2 class="font-semibold text-gray-900 dark:text-gray-100">Your preview</h2>
        <p class="mt-2 text-sm leading-6 text-gray-600 dark:text-gray-300">
          Preview makes no changes. Apply checks the selected records again, so final totals may
          differ. Records imported afterward need a new preview.
        </p>
        <dl class="mt-4 grid grid-cols-2 gap-4 sm:grid-cols-3">
          <div :for={{label, count} <- count_rows(@maintenance.preview.counts)}>
            <dt class="text-xs text-gray-600 dark:text-gray-400">{label}</dt>
            <dd class="mt-1 text-xl font-semibold tabular-nums text-gray-900 dark:text-gray-100">
              {count}
            </dd>
          </div>
        </dl>
      </section>

      <section
        :if={@maintenance.last_run}
        class="mt-6 rounded-xl border border-gray-200 p-4 sm:p-6 dark:border-gray-700"
      >
        <h2 class="font-semibold text-gray-900 dark:text-gray-100">Last enrichment run</h2>
        <p class="mt-2 text-sm text-gray-700 dark:text-gray-300">
          {status_label(@maintenance.last_run)}
        </p>
        <dl class="mt-3 space-y-2 text-sm">
          <div>
            <dt class="text-gray-500 dark:text-gray-400">Started</dt>
            <dd class="text-gray-800 dark:text-gray-200">
              {timestamp(@maintenance.last_run.started_at)}
            </dd>
          </div>
          <div>
            <dt class="text-gray-500 dark:text-gray-400">Finished</dt>
            <dd class="text-gray-800 dark:text-gray-200">
              {timestamp(@maintenance.last_run.finished_at)}
            </dd>
          </div>
        </dl>
        <p :if={@maintenance.last_run.error} class="mt-3 text-sm text-red-700 dark:text-red-300">
          {error_message(@maintenance.last_run.error)}
        </p>
        <dl :if={@maintenance.last_run.counts} class="mt-4 grid grid-cols-2 gap-4 sm:grid-cols-3">
          <div :for={{label, count} <- count_rows(@maintenance.last_run.counts)}>
            <dt class="text-xs text-gray-600 dark:text-gray-400">{label}</dt>
            <dd class="mt-1 text-xl font-semibold tabular-nums text-gray-900 dark:text-gray-100">
              {count}
            </dd>
          </div>
        </dl>
      </section>
    </main>
    """
  end
end
