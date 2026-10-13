defmodule ResidencySchedule.Observability.RenderDiagnostics do
  @moduledoc """
  Fixed render metadata captured before LiveView clears its change tracking.

  Counts describe available visible workload, not cells visited by the diff.
  Process reductions are BEAM work, and memory samples are process size, not
  allocation or CPU time. Pending encoder attribution is one-shot and local to
  the rendering process; initial joins encoded elsewhere remain uncorrelated.
  """
  alias Phoenix.LiveView
  alias Phoenix.LiveView.Utils
  alias ResidencySchedule.Observability

  @state {__MODULE__, :state}
  @pending {__MODULE__, :pending}
  @flags ~w(name_col_px visible_resident_groups all_slots rotation_modal filter_year viewed_aca_year schedules unified_residents schedule_window)a
  @schedule_events ~w(scroll_to_schedule open_rotation_details close_rotation_details tour_completed restart_tour filter_year view_academic_year request_delete cancel_delete delete_schedule update_window)
  @calendar_events ~w(set_view prev next today select_day open_day_view close_modal toggle_filter_panel toggle_resident_filter toggle_rotation_filter clear_resident_filter clear_rotation_filter restore_prefs tour_completed restart_tour)

  @doc false
  def on_mount(:default, _, _, socket) do
    if enabled?() and view(socket.view) do
      Process.delete(@pending)
      Process.put(@state, %{sequence: 0, cause: "initial", event: nil})

      socket =
        socket
        |> LiveView.attach_hook(__MODULE__, :handle_event, &event/3)
        |> LiveView.attach_hook(__MODULE__, :handle_info, &info/2)
        |> LiveView.attach_hook(__MODULE__, :handle_async, &async/3)

      socket =
        if socket.router,
          do: LiveView.attach_hook(socket, __MODULE__, :handle_params, &params/3),
          else: socket

      {:cont, socket}
    else
      {:cont, socket}
    end
  end

  @doc false
  def assign_counts(socket, groups, slots, rendered_window \\ nil) do
    if enabled?() do
      rendered = rendered_window || %{groups: groups, slots: slots}

      counts =
        Map.merge(
          workload_counts(groups, slots, "app"),
          workload_counts(rendered.groups, rendered.slots, "app.rendered")
        )

      %{socket | private: Map.put(socket.private, :render_counts, counts)}
    else
      socket
    end
  end

  defp workload_counts(groups, slots, prefix) do
    rows = Enum.flat_map(groups, &elem(&1, 1))

    %{
      "#{prefix}.rows.count" => length(rows),
      "#{prefix}.slots.count" => length(slots),
      "#{prefix}.cells.count" => Enum.reduce(rows, 0, &(length(&1.cells) + &2)),
      "#{prefix}.cohorts.count" => length(groups)
    }
  end

  @doc false
  def start(%{socket: socket} = metadata) do
    Process.delete(@pending)
    state = Process.get(@state, %{sequence: 0, cause: "unknown", event: nil})
    sequence = state.sequence + 1
    changed = Map.get(socket.assigns, :__changed__, %{})

    attributes = %{
      "app.render.sequence" => sequence,
      "app.render.initial" => sequence == 1,
      "app.render.force" => metadata[:force?] == true,
      "app.render.changed" => metadata[:changed?] == true,
      "app.render.trigger" => state.cause,
      "deployment.sha" => :persistent_term.get({Observability, :deployment_version}, "unknown")
    }

    attributes =
      Enum.reduce(@flags, attributes, fn flag, attrs ->
        Map.put(
          attrs,
          "app.render.changed.#{flag}",
          is_nil(changed) or Map.has_key?(changed, flag)
        )
      end)

    attributes =
      if state.cause == "event",
        do: Map.put(attributes, "app.render.event", state.event),
        else: attributes

    attributes = Map.merge(attributes, Map.get(socket.private, :render_counts, %{}))

    Process.put(@state, %{
      sequence: sequence,
      cause: "unknown",
      event: nil,
      before: snapshot(),
      correlation: %{
        "view" => view(socket.view),
        "lifecycle" => if(is_pid(socket.transport_pid), do: "connected", else: "static"),
        "app.render.sequence" => sequence
      }
    })

    attributes
  end

  @doc false
  def finish(stage, span) do
    case Process.get(@state) do
      %{before: before, correlation: correlation} = state ->
        after_sample = snapshot()
        Process.put(@state, Map.drop(state, [:before, :correlation]))

        if stage == :stop and not is_nil(span) do
          Process.put(@pending, %{span: span, attributes: correlation})
        else
          Process.delete(@pending)
        end

        %{
          "app.process.reductions.delta" => max(after_sample.reductions - before.reductions, 0),
          "app.process.memory.before_bytes" => before.memory,
          "app.process.memory.after_bytes" => after_sample.memory,
          "app.process.mailbox.before_count" => before.message_queue_len,
          "app.process.mailbox.after_count" => after_sample.message_queue_len
        }

      _ ->
        Process.delete(@pending)
        %{}
    end
  end

  @doc false
  def take_encoding(kind) do
    pending = Process.delete(@pending)
    if kind == :diff, do: pending
  end

  @doc false
  def clear do
    Process.delete(@pending)
    Process.delete(@state)
    :ok
  end

  @doc false
  def callback_finished(stage, metadata) do
    if stage == :exception or
         (stage == :stop and not Utils.changed?(metadata.socket)) do
      callback("unknown")
    end

    :ok
  end

  defp event(name, _, socket) do
    allowed = if view(socket.view) == "schedule", do: @schedule_events, else: @calendar_events
    callback("event", if(name in allowed, do: name, else: "_OTHER"))
    {:cont, socket}
  end

  defp info(_, socket) do
    callback("unknown")
    {:cont, socket}
  end

  defp async(_, _, socket) do
    callback("unknown")
    {:cont, socket}
  end

  defp params(_, _, socket) do
    if Process.get(@state, %{})[:sequence] == 0,
      do: callback("initial"),
      else: callback("params")

    {:cont, socket}
  end

  defp callback(cause, event \\ nil) do
    Process.delete(@pending)

    if enabled?() do
      state = Process.get(@state, %{sequence: 0})
      Process.put(@state, %{sequence: state.sequence, cause: cause, event: event})
    else
      Process.delete(@state)
    end
  end

  defp snapshot,
    do: self() |> Process.info([:reductions, :memory, :message_queue_len]) |> Map.new()

  defp enabled?, do: not is_nil(Process.whereis(Observability.RequestHandler))
  defp view(ResidencyScheduleWeb.ScheduleLive.Index), do: "schedule"
  defp view(ResidencyScheduleWeb.CalendarLive.Index), do: "calendar"
  defp view(_), do: nil
end
