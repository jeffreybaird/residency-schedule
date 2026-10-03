defmodule ResidencyScheduleWeb.EditLive.Index do
  use ResidencyScheduleWeb, :live_view

  on_mount {ResidencyScheduleWeb.UserAuth, :ensure_admin}

  alias ResidencySchedule.Rotations
  alias ResidencySchedule.ScheduleEditor
  alias ResidencySchedule.Schedules

  @assignment_fields [:rotation_type, :start_date, :end_date]
  @abbreviations %{
    "leave_of_absence" => "LOA",
    "admin" => "ADMIN",
    "admin_mfm" => "ADMIN/MFM",
    "cob" => "COB",
    "gog_colpo" => "GOG/Colpo",
    "mfm" => "MFM",
    "mfm_pain" => "MFM/pain",
    "mfm_pm" => "MFM PM",
    "orientation" => "Orient",
    "oncology_orientation" => "ONC (orient)",
    "highland_obstetrics_orientation" => "HHOB (orient)",
    "strong_gynecology_orientation" => "GYN (orient)",
    "highland_gynecology_orientation" => "HGYN (orient)",
    "strong_obstetrics_orientation" => "OB (orient)",
    "ambulatory" => "AMB",
    "away_rotation" => "AWAY",
    "elective" => "Elec",
    "float" => "FLOAT",
    "strong_gynecology" => "GYN",
    "highland_gynecology" => "HGYN",
    "highland_obstetrics" => "HHOB",
    "highland_night_float" => "HNF",
    "highland_weekend_days" => "HWD",
    "highland_weekend_nights" => "HWN",
    "night_float" => "NF",
    "strong_obstetrics" => "OB",
    "oncology" => "ONC",
    "post_call" => "P",
    "rei" => "REI",
    "strong_weekend_days" => "SWD",
    "strong_weekend_nights" => "SWN",
    "swing" => "Swing",
    "urogynecology" => "UG",
    "ultrasound" => "US",
    "vacation" => "Vac"
  }

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       schedules: Schedules.list_editable_schedules(),
       editor: nil,
       draft: [],
       slots: [],
       grid: %{},
       history: [],
       selection: nil,
       assignment_form: nil,
       load_error: nil,
       save_error: nil,
       saved: false,
       next_id: 1,
       filter_year: nil
     )}
  end

  @impl true
  def handle_event("load_schedule", %{"schedule_id" => id}, socket) do
    case ScheduleEditor.load(integer_id(id)) do
      {:ok, state} -> {:noreply, load_baseline(socket, state)}
      {:error, reason} -> {:noreply, assign(socket, load_error: reason)}
    end
  end

  def handle_event(event, %{"id" => id}, socket)
      when event in ["edit_assignment", "select_assignment"] do
    case selected_rotation(socket.assigns.draft, id) do
      nil -> {:noreply, assign(socket, save_error: "Assignment does not belong to this schedule")}
      rotation -> {:noreply, open_form(socket, %{action: :update, id: rotation.id}, rotation)}
    end
  end

  def handle_event("add_assignment", %{"resident-id" => id}, socket) do
    resident_id = integer_id(id)

    if socket.assigns.editor &&
         Enum.any?(socket.assigns.editor.residents, &(&1.id == resident_id)) do
      {:noreply,
       open_form(socket, %{action: :add, resident_id: resident_id}, %{
         rotation_type: "ambulatory",
         start_date: "",
         end_date: ""
       })}
    else
      {:noreply, assign(socket, save_error: "Resident does not belong to this schedule")}
    end
  end

  def handle_event("select_slot", params, socket) do
    case selected_slot(socket.assigns, params) do
      nil -> {:noreply, socket}
      selection -> {:noreply, open_slot(socket, selection)}
    end
  end

  def handle_event("choose_slot_assignment", %{"id" => id}, socket) do
    case socket.assigns.selection do
      %{action: :choose, resident_id: resident_id, slot_index: index} = selection ->
        case selected_rotation(Map.get(socket.assigns.grid, {resident_id, index}, []), id) do
          nil -> {:noreply, socket}
          rotation -> {:noreply, open_slot_rotation(socket, selection, rotation)}
        end

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("add_slot_assignment", params, socket) do
    case {socket.assigns.selection, selected_slot(socket.assigns, params)} do
      {%{action: :choose, resident_id: id, slot_index: index},
       %{resident_id: id, slot_index: index} = selection} ->
        {:noreply, open_slot_add(socket, selection)}

      _ ->
        {:noreply, socket}
    end
  end

  def handle_event("stage_assignment", %{"assignment" => attrs}, socket) do
    case validate_form(socket, attrs) do
      {:ok, values} -> {:noreply, stage_form(socket, values)}
      {:error, reason} -> {:noreply, assign(socket, save_error: reason)}
    end
  end

  def handle_event("delete_assignment", %{"id" => id}, socket) do
    case selected_rotation(socket.assigns.draft, id) do
      nil ->
        {:noreply, assign(socket, save_error: "Assignment does not belong to this schedule")}

      rotation ->
        {:noreply,
         stage_draft(socket, Enum.reject(socket.assigns.draft, &(&1.id == rotation.id)))}
    end
  end

  def handle_event("undo", _params, socket) do
    case socket.assigns.history do
      [] -> {:noreply, socket}
      [previous | rest] -> {:noreply, socket |> assign(history: rest) |> show_draft(previous)}
    end
  end

  def handle_event("cancel_edits", _params, socket) do
    if socket.assigns.editor,
      do: {:noreply, load_baseline(socket, socket.assigns.editor)},
      else: {:noreply, socket}
  end

  def handle_event("cancel", _params, socket), do: handle_event("cancel_edits", %{}, socket)

  def handle_event("close_assignment", _params, socket),
    do: {:noreply, assign(socket, selection: nil, assignment_form: nil)}

  def handle_event("filter_year", %{"year" => year}, socket) do
    {:noreply,
     assign(socket,
       filter_year: if(year in ["1", "2", "3", "4"], do: integer_id(year), else: nil)
     )}
  end

  def handle_event("save", _params, socket) do
    case ScheduleEditor.commit(
           socket.assigns.editor,
           operations(socket.assigns.editor, socket.assigns.draft)
         ) do
      {:ok, state} -> {:noreply, socket |> load_baseline(state) |> assign(saved: true)}
      {:error, reason} -> {:noreply, assign(socket, save_error: reason, saved: false)}
    end
  end

  def handle_event(_event, _params, socket), do: {:noreply, socket}

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-gray-50 dark:bg-gray-950">
      <div class="sticky top-14 z-40 border-b bg-white dark:bg-gray-900 px-4 py-3 flex flex-wrap items-center gap-3">
        <.form for={to_form(%{}, as: nil)} id="load-editor-form" phx-submit="load_schedule">
          <div class="flex gap-2 items-center">
            <select name="schedule_id" aria-label="Academic year" class="rounded border px-2 py-1">
              <option :for={schedule <- @schedules} value={schedule.id}>{schedule.label}</option>
            </select>
            <button type="submit" class="rounded bg-amber-500 px-3 py-2 text-white text-sm">
              Load schedule to edit
            </button>
          </div>
        </.form>
        <%= if @editor do %>
          <span class="text-sm text-gray-600 dark:text-gray-300">
            {@editor.label} · {length(@draft)} assignments
          </span>
          <button
            phx-click="undo"
            disabled={@history == []}
            class="rounded border px-3 py-2 text-sm disabled:opacity-40"
          >
            Undo
          </button>
          <button phx-click="cancel_edits" class="rounded border px-3 py-2 text-sm">
            Cancel edits
          </button>
          <button phx-click="save" class="rounded bg-blue-600 px-3 py-2 text-white text-sm">
            Save changes
          </button>
          <span :if={@saved} role="status" class="text-sm text-green-700 dark:text-green-300">
            Changes saved
          </span>
        <% end %>
      </div>
      <p
        :if={@load_error}
        id="edit-load-error"
        role="alert"
        class="p-4 text-red-700 dark:text-red-300"
      >
        {@load_error}
      </p>
      <p
        :if={@save_error}
        id="edit-save-error"
        role="alert"
        class="p-4 text-red-700 dark:text-red-300"
      >
        {@save_error}
      </p>
      <%= if @editor do %>
        <div class="p-4 text-sm text-gray-600 dark:text-gray-300">
          Click a schedule slot to choose a shift. Each badge is a separate assignment;
          selecting a badge edits its complete saved date range.
          Changes stay in this draft until you save. Resident names are read-only.
          <span :if={@history != []} class="font-semibold text-amber-700 dark:text-amber-300">
            Unsaved changes
          </span>
        </div>
        <div class="px-4 pb-3 flex gap-2 items-center text-sm">
          <span>Residents:</span>
          <button phx-click="filter_year" phx-value-year="all" class="rounded border px-2 py-1">
            All
          </button>
          <button
            :for={year <- 1..4}
            phx-click="filter_year"
            phx-value-year={year}
            class="rounded border px-2 py-1"
          >
            R{year}
          </button>
        </div>
        <div class="overflow-x-auto pb-6">
          <table id="editor-grid" class="border-separate border-spacing-0 text-xs">
            <thead>
              <tr class="bg-gray-100 dark:bg-gray-800">
                <th class="sticky left-0 z-20 bg-gray-100 dark:bg-gray-800 border-b border-r px-3 py-2 text-left min-w-52">
                  Resident
                </th>
                <th
                  :for={{index, start_date, end_date} <- @slots}
                  data-slot-index={index}
                  data-start-date={start_date}
                  data-end-date={end_date}
                  class="border-b border-r px-3 py-2 whitespace-nowrap min-w-32"
                >
                  {Calendar.strftime(start_date, "%b %-d, %Y")}<br />– {Calendar.strftime(
                    end_date,
                    "%b %-d, %Y"
                  )}
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={resident <- visible_residents(@editor.residents, @filter_year)}>
                <td class="sticky left-0 z-10 bg-white dark:bg-gray-900 border-b border-r px-3 py-2">
                  <div class="font-semibold">{resident.position_code} · {resident.name}</div>
                  <button
                    phx-click="add_assignment"
                    phx-value-resident-id={resident.id}
                    class="mt-1 text-blue-700 dark:text-blue-300"
                  >
                    + Add assignment
                  </button>
                </td>
                <td
                  :for={{index, start_date, _end_date} <- @slots}
                  class="relative border-b border-r bg-white dark:bg-gray-900 px-1 py-1 align-top h-16"
                >
                  <button
                    id={"select-slot-#{resident.id}-#{index}"}
                    type="button"
                    phx-click="select_slot"
                    phx-value-resident-id={resident.id}
                    phx-value-slot-index={index}
                    aria-label={"Choose shift for #{resident.position_code} · #{resident.name}, slot #{index + 1}"}
                    aria-haspopup="dialog"
                    class="absolute inset-0 w-full h-full hover:bg-blue-50 dark:hover:bg-blue-950 focus-visible:outline-2 focus-visible:outline-blue-600 focus-visible:-outline-offset-2"
                  >
                    <span :if={Map.get(@grid, {resident.id, index}, []) == []} class="text-gray-400">
                      + Choose shift
                    </span>
                  </button>
                  <div
                    :for={rotation <- Map.get(@grid, {resident.id, index}, [])}
                    data-rotation-id={rotation.id}
                    data-start-date={rotation.start_date}
                    data-end-date={rotation.end_date}
                    class="relative pointer-events-none mb-1 flex items-center gap-1"
                  >
                    <button
                      phx-click={
                        if(start_date == rotation.start_date,
                          do: "edit_assignment",
                          else: "select_assignment"
                        )
                      }
                      phx-value-id={rotation.id}
                      title={"#{Rotations.rotation_type_label(rotation.rotation_type)}: #{rotation.start_date} – #{rotation.end_date}. Edit entire assignment."}
                      class={[
                        "pointer-events-auto rounded px-2 py-1 font-semibold whitespace-nowrap",
                        Rotations.rotation_type_color(rotation.rotation_type)
                      ]}
                    >
                      {abbreviation(rotation.rotation_type)}
                    </button>
                    <button
                      :if={start_date == rotation.start_date}
                      phx-click="delete_assignment"
                      phx-value-id={rotation.id}
                      aria-label={"Remove #{abbreviation(rotation.rotation_type)} assignment #{rotation.start_date} – #{rotation.end_date}"}
                      title="Remove entire assignment from draft"
                      class="pointer-events-auto px-1 text-red-700 dark:text-red-300"
                    >
                      ×
                    </button>
                  </div>
                </td>
              </tr>
            </tbody>
          </table>
        </div>
      <% end %>
      <%= if @selection do %>
        <div
          id="assignment-backdrop"
          phx-remove={JS.pop_focus()}
          class="fixed inset-0 z-50 bg-black/30 flex items-center justify-center p-4"
        >
          <.focus_wrap id="assignment-focus-wrap" class="w-full max-w-md">
            <div
              id="assignment-dialog"
              class="rounded-lg bg-white dark:bg-gray-900 p-6 shadow-xl w-full max-w-md"
              role="dialog"
              aria-modal="true"
              aria-labelledby="assignment-title"
              phx-window-keydown="close_assignment"
              phx-key="Escape"
              phx-mounted={
                JS.push_focus(to: selection_focus_target(@selection))
                |> JS.focus_first(to: "#assignment-dialog")
              }
            >
              <h2 id="assignment-title" class="text-lg font-semibold">
                {if(slot_selection?(@selection),
                  do: "Choose shift",
                  else: if(@selection.action == :add, do: "Add assignment", else: "Edit assignment")
                )}
              </h2>
              <p
                :if={slot_selection?(@selection)}
                class="mt-2 text-sm text-gray-600 dark:text-gray-300"
              >
                {selection_resident(@editor.residents, @selection).name}
              </p>
              <p
                :if={!slot_selection?(@selection)}
                class="mt-2 text-sm text-gray-600 dark:text-gray-300"
              >
                These dates describe the whole assignment, including every grid column it spans.
              </p>
              <p :if={@save_error} role="alert" class="mt-2 text-sm text-red-700 dark:text-red-300">
                {@save_error}
              </p>
              <div :if={@selection.action == :choose} class="mt-4 space-y-3">
                <p class="text-sm">Choose the assignment to change, or add another shift.</p>
                <button
                  :for={
                    {rotation, number} <-
                      Enum.with_index(
                        Map.get(@grid, {@selection.resident_id, @selection.slot_index}, []),
                        1
                      )
                  }
                  type="button"
                  phx-click="choose_slot_assignment"
                  phx-value-id={rotation.id}
                  class="block w-full rounded border px-3 py-2 text-left hover:bg-gray-100 dark:hover:bg-gray-800"
                >
                  {number}. {Rotations.rotation_type_label(rotation.rotation_type)}
                </button>
                <button
                  type="button"
                  phx-click="add_slot_assignment"
                  phx-value-resident-id={@selection.resident_id}
                  phx-value-slot-index={@selection.slot_index}
                  class="block w-full rounded border px-3 py-2 text-blue-700 dark:text-blue-300"
                >
                  + Add another shift
                </button>
                <button type="button" phx-click="close_assignment" class="rounded border px-3 py-2">
                  Cancel
                </button>
              </div>
              <.form
                :if={@assignment_form}
                for={@assignment_form}
                id="assignment-form"
                phx-submit="stage_assignment"
                phx-mounted={JS.focus_first(to: "#assignment-form")}
                class="mt-4 space-y-3"
              >
                <.input
                  field={@assignment_form[:rotation_type]}
                  type="select"
                  label={if(slot_selection?(@selection), do: "Shift", else: "Rotation")}
                  options={rotation_options()}
                />
                <.input
                  :if={!slot_selection?(@selection)}
                  field={@assignment_form[:start_date]}
                  type="date"
                  label="Assignment start date"
                />
                <.input
                  :if={!slot_selection?(@selection)}
                  field={@assignment_form[:end_date]}
                  type="date"
                  label="Assignment end date"
                />
                <div class="flex justify-end gap-2 pt-3">
                  <button type="button" phx-click="close_assignment" class="rounded border px-3 py-2">
                    Cancel
                  </button>
                  <button type="submit" class="rounded bg-blue-600 text-white px-3 py-2">
                    Apply to draft
                  </button>
                </div>
              </.form>
            </div>
          </.focus_wrap>
        </div>
      <% end %>
    </div>
    """
  end

  defp load_baseline(socket, state) do
    socket
    |> assign(editor: state, history: [], load_error: nil, next_id: 1)
    |> show_draft(state.rotations)
  end

  defp show_draft(socket, draft) do
    slots = Rotations.date_slots(draft)
    by_resident = Enum.group_by(draft, & &1.schedule_resident_id)

    grid =
      for {resident_id, rotations} <- by_resident,
          {index, start_date, _end_date} <- slots,
          into: %{} do
        {{resident_id, index},
         Enum.filter(
           rotations,
           &(Date.compare(&1.start_date, start_date) != :gt and
               Date.compare(&1.end_date, start_date) != :lt)
         )}
      end

    assign(socket,
      draft: draft,
      slots: slots,
      grid: grid,
      selection: nil,
      assignment_form: nil,
      save_error: nil,
      saved: false
    )
  end

  defp stage_draft(socket, draft) do
    socket
    |> assign(history: [socket.assigns.draft | socket.assigns.history])
    |> show_draft(draft)
  end

  defp open_form(socket, selection, attrs) do
    params = Map.new(@assignment_fields, &{Atom.to_string(&1), to_string(Map.fetch!(attrs, &1))})

    assign(socket,
      selection: selection,
      assignment_form: to_form(params, as: :assignment),
      save_error: nil
    )
  end

  defp selected_slot(%{editor: editor, slots: slots}, %{
         "resident-id" => id,
         "slot-index" => index
       })
       when not is_nil(editor) and is_binary(index) do
    resident_id = integer_id(id)

    with true <- Enum.any?(editor.residents, &(&1.id == resident_id)),
         {slot_index, ""} when slot_index >= 0 <- Integer.parse(index),
         {^slot_index, start_date, end_date} <- Enum.find(slots, &(elem(&1, 0) == slot_index)) do
      %{
        source: :slot,
        resident_id: resident_id,
        slot_index: slot_index,
        start_date: start_date,
        end_date: end_date
      }
    else
      _ -> nil
    end
  end

  defp selected_slot(_assigns, _params), do: nil

  defp open_slot(socket, selection) do
    case Map.get(socket.assigns.grid, {selection.resident_id, selection.slot_index}, []) do
      [] ->
        open_slot_add(socket, selection)

      [rotation] ->
        open_slot_rotation(socket, selection, rotation)

      _ ->
        assign(socket,
          selection: Map.put(selection, :action, :choose),
          assignment_form: nil,
          save_error: nil
        )
    end
  end

  defp open_slot_add(socket, selection) do
    open_form(socket, Map.put(selection, :action, :add), %{
      rotation_type: "ambulatory",
      start_date: selection.start_date,
      end_date: selection.end_date
    })
  end

  defp open_slot_rotation(socket, selection, rotation) do
    selection =
      Map.merge(selection, %{
        action: :update,
        id: rotation.id,
        start_date: rotation.start_date,
        end_date: rotation.end_date
      })

    open_form(socket, selection, rotation)
  end

  defp slot_selection?(selection), do: Map.get(selection, :source) == :slot

  defp selection_focus_target(%{source: :slot, resident_id: id, slot_index: index}),
    do: "#select-slot-#{id}-#{index}"

  defp selection_focus_target(_selection), do: ":focus"

  defp selection_resident(residents, selection),
    do: Enum.find(residents, &(&1.id == selection.resident_id))

  defp validate_form(%{assigns: %{selection: %{action: :choose}}}, _attrs),
    do: {:error, "Choose an assignment first"}

  defp validate_form(
         %{assigns: %{editor: editor, selection: %{source: :slot} = selection}},
         attrs
       )
       when is_map(attrs) do
    ScheduleEditor.validate_assignment(editor, %{
      rotation_type: Map.get(attrs, "rotation_type"),
      start_date: selection.start_date,
      end_date: selection.end_date
    })
  end

  defp validate_form(%{assigns: %{editor: editor, selection: selection}}, attrs)
       when not is_nil(editor) and not is_nil(selection),
       do: ScheduleEditor.validate_assignment(editor, attrs)

  defp validate_form(_socket, _attrs), do: {:error, "Select an assignment first"}

  defp stage_form(%{assigns: %{selection: %{action: :update, id: id}}} = socket, attrs) do
    draft =
      Enum.map(socket.assigns.draft, fn rotation ->
        if rotation.id == id, do: Map.merge(rotation, attrs), else: rotation
      end)

    stage_draft(socket, draft)
  end

  defp stage_form(%{assigns: %{selection: %{action: :add, resident_id: id}}} = socket, attrs) do
    rotation = Map.merge(attrs, %{id: "new-#{socket.assigns.next_id}", schedule_resident_id: id})

    socket
    |> assign(next_id: socket.assigns.next_id + 1)
    |> stage_draft(socket.assigns.draft ++ [rotation])
  end

  defp operations(nil, _draft), do: []

  defp operations(editor, draft) do
    current = Map.new(draft, &{&1.id, &1})
    original_ids = MapSet.new(editor.rotations, & &1.id)

    updates =
      Enum.flat_map(editor.rotations, fn original ->
        case Map.get(current, original.id) do
          nil -> [%{action: :delete, rotation_id: original.id}]
          updated -> changed_operation(original, updated)
        end
      end)

    additions =
      draft
      |> Enum.reject(&MapSet.member?(original_ids, &1.id))
      |> Enum.map(fn rotation ->
        %{
          action: :add,
          schedule_resident_id: rotation.schedule_resident_id,
          attrs: Map.take(rotation, @assignment_fields)
        }
      end)

    updates ++ additions
  end

  defp changed_operation(original, updated) do
    attrs = Map.take(updated, @assignment_fields)

    if Map.take(original, @assignment_fields) == attrs,
      do: [],
      else: [%{action: :update, rotation_id: original.id, attrs: attrs}]
  end

  defp selected_rotation(rotations, id) when is_binary(id),
    do: Enum.find(rotations, &(to_string(&1.id) == id))

  defp selected_rotation(_rotations, _id), do: nil

  defp integer_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {number, ""} when number > 0 and number <= 9_223_372_036_854_775_807 -> number
      _ -> nil
    end
  end

  defp integer_id(_id), do: nil
  defp abbreviation(type), do: Map.get(@abbreviations, type, Rotations.rotation_type_label(type))
  defp visible_residents(residents, nil), do: Enum.sort_by(residents, & &1.position_code)

  defp visible_residents(residents, year),
    do: residents |> Enum.filter(&(&1.residency_year == year)) |> Enum.sort_by(& &1.position_code)

  defp rotation_options,
    do:
      Rotations.all_rotation_types()
      |> Enum.sort()
      |> Enum.map(&{Rotations.rotation_type_label(&1), &1})
end
