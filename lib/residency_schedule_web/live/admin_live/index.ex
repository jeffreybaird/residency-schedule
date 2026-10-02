defmodule ResidencyScheduleWeb.AdminLive.Index do
  use ResidencyScheduleWeb, :live_view

  on_mount {ResidencyScheduleWeb.UserAuth, :ensure_admin}

  alias ResidencySchedule.Accounts
  alias ResidencySchedule.ChangeRequests
  alias ResidencySchedule.Residents
  alias ResidencySchedule.Rotations
  alias ResidencySchedule.Schedules
  alias ResidencySchedule.ShiftOverrides

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: ChangeRequests.subscribe()

    {:ok,
     assign(socket,
       schedules: Schedules.list_schedules(),
       delete_confirm_id: nil,
       pending_users: Accounts.list_pending_users(),
       approved_users: Accounts.list_approved_users(),
       role_error: nil,
       existing_overrides: ShiftOverrides.list_all_overrides(),
       pending_requests: ChangeRequests.list_requests(socket.assigns.current_user, :pending),
       request_error: nil,
       override_rotation_type: nil,
       override_start_date: nil,
       override_end_date: nil,
       available_rotations: [],
       override_rotation_id: nil,
       available_covering_residents: [],
       override_covering_resident_id: nil,
       override_error: nil,
       override_success: nil,
       has_password: Accounts.has_password?(socket.assigns.current_user),
       password_error: nil,
       password_success: nil,
       password_form_version: 0
     )}
  end

  @impl true
  def handle_event("request_delete", %{"id" => id}, socket) do
    {:noreply, assign(socket, delete_confirm_id: String.to_integer(id))}
  end

  @impl true
  def handle_event("cancel_delete", _params, socket) do
    {:noreply, assign(socket, delete_confirm_id: nil)}
  end

  @impl true
  def handle_event("confirm_delete", %{"id" => id}, socket) do
    Schedules.delete_schedule(String.to_integer(id))
    {:noreply, assign(socket, schedules: Schedules.list_schedules(), delete_confirm_id: nil)}
  end

  @impl true
  def handle_event("override_change", params, socket) do
    # phx-change on a form sends ALL current field values, so read directly from params.
    # nilify_empty treats "" and nil as absent — no || fallback needed.
    rotation_type = nilify_empty(params["rotation_type"])
    start_date = parse_date(params["start_date"])
    end_date = parse_date(params["end_date"])
    rotation_id = nilify_empty(params["rotation_id"])
    covering_id = nilify_empty(params["covering_resident_id"])

    available =
      if rotation_type && start_date && end_date &&
           Date.compare(start_date, end_date) != :gt do
        ShiftOverrides.list_rotations_for_type_in_range(rotation_type, start_date, end_date)
      else
        []
      end

    covering_residents =
      case rotation_id && Enum.find(available, fn rot -> to_string(rot.id) == rotation_id end) do
        nil -> []
        rot -> Residents.list_residents_for_schedule(rot.schedule_resident.schedule_id)
      end

    {:noreply,
     assign(socket,
       override_rotation_type: rotation_type,
       override_start_date: start_date,
       override_end_date: end_date,
       available_rotations: available,
       override_rotation_id: rotation_id,
       available_covering_residents: covering_residents,
       override_covering_resident_id: covering_id,
       override_error: nil,
       override_success: nil
     )}
  end

  @impl true
  def handle_event("save_override", _params, socket) do
    with rotation_id when rotation_id not in [nil, ""] <- socket.assigns.override_rotation_id,
         covering_id when covering_id not in [nil, ""] <-
           socket.assigns.override_covering_resident_id,
         start_date when not is_nil(start_date) <- socket.assigns.override_start_date,
         end_date when not is_nil(end_date) <- socket.assigns.override_end_date do
      attrs = %{
        rotation_id: String.to_integer(rotation_id),
        covering_schedule_resident_id: String.to_integer(covering_id),
        override_start_date: start_date,
        override_end_date: end_date
      }

      case ShiftOverrides.create_override(attrs) do
        {:ok, _} ->
          {:noreply,
           assign(socket,
             existing_overrides: ShiftOverrides.list_all_overrides(),
             override_rotation_type: nil,
             override_start_date: nil,
             override_end_date: nil,
             available_rotations: [],
             override_rotation_id: nil,
             available_covering_residents: [],
             override_covering_resident_id: nil,
             override_error: nil,
             override_success: "Override saved."
           )}

        {:error, changeset} ->
          msg = format_changeset_errors(changeset)
          {:noreply, assign(socket, override_error: msg, override_success: nil)}
      end
    else
      _ ->
        {:noreply,
         assign(socket, override_error: "Please fill in all fields.", override_success: nil)}
    end
  end

  @impl true
  def handle_event("approve_request", %{"id" => id}, socket) do
    socket.assigns.current_user
    |> ChangeRequests.approve_request(String.to_integer(id))
    |> refresh_requests(socket)
  end

  @impl true
  def handle_event("deny_request", %{"id" => id}, socket) do
    socket.assigns.current_user
    |> ChangeRequests.deny_request(String.to_integer(id))
    |> refresh_requests(socket)
  end

  @impl true
  def handle_event("delete_override", %{"id" => id}, socket) do
    ShiftOverrides.delete_override(String.to_integer(id))
    {:noreply, assign(socket, existing_overrides: ShiftOverrides.list_all_overrides())}
  end

  @impl true
  def handle_event("approve_user", %{"id" => id}, socket) do
    user = Accounts.get_user!(String.to_integer(id))
    Accounts.approve_user(user)

    {:noreply,
     assign(socket,
       pending_users: Accounts.list_pending_users(),
       approved_users: Accounts.list_approved_users()
     )}
  end

  @impl true
  def handle_event("deny_user", %{"id" => id}, socket) do
    user = Accounts.get_user!(String.to_integer(id))

    case Accounts.deny_user(user) do
      {:ok, _user} ->
        {:noreply,
         assign(socket,
           pending_users: Accounts.list_pending_users(),
           approved_users: Accounts.list_approved_users(),
           role_error: nil
         )}

      {:error, :already_approved} ->
        {:noreply,
         assign(socket, role_error: "This user is already approved — revoke them instead.")}

      {:error, _changeset} ->
        {:noreply, assign(socket, role_error: "Could not deny this user.")}
    end
  end

  @impl true
  def handle_event("revoke_user", %{"id" => id}, socket) do
    user = Accounts.get_user!(String.to_integer(id))

    case Accounts.revoke_user(user) do
      {:ok, _user} ->
        {:noreply,
         assign(socket,
           pending_users: Accounts.list_pending_users(),
           approved_users: Accounts.list_approved_users(),
           role_error: nil
         )}

      {:error, :admin_cannot_be_revoked} ->
        {:noreply,
         assign(socket, role_error: "Admins cannot be revoked — change their role first.")}

      {:error, _changeset} ->
        {:noreply, assign(socket, role_error: "Could not revoke this user.")}
    end
  end

  @impl true
  def handle_event("set_role", %{"user_id" => user_id, "role" => role_param}, socket) do
    user = Accounts.get_user!(String.to_integer(user_id))

    case set_role_from_param(user, role_param) do
      {:ok, _user} ->
        {:noreply,
         assign(socket,
           pending_users: Accounts.list_pending_users(),
           approved_users: Accounts.list_approved_users(),
           role_error: nil
         )}

      {:error, message} ->
        {:noreply, assign(socket, role_error: message)}
    end
  end

  @impl true
  def handle_event("change_password", params, socket) do
    case change_password_from_form(params, socket.assigns.current_user) do
      {:ok, updated_user} ->
        {:noreply,
         assign(socket,
           current_user: updated_user,
           has_password: true,
           password_error: nil,
           password_success: "Your password has been updated.",
           password_form_version: socket.assigns.password_form_version + 1
         )}

      {:error, message} ->
        {:noreply, assign(socket, password_error: message, password_success: nil)}
    end
  end

  defp change_password_from_form(params, user) do
    with :ok <-
           validate_password_confirmation(params["new_password"], params["confirm_password"]),
         {:ok, updated_user} <-
           Accounts.change_password(
             user,
             params["current_password"] || "",
             params["new_password"]
           ) do
      {:ok, updated_user}
    else
      {:error, :confirmation_mismatch} ->
        {:error, "New passwords do not match."}

      {:error, :invalid_current_password} ->
        {:error, "Current password is incorrect."}

      {:error, %Ecto.Changeset{} = changeset} ->
        {:error, changeset_error_message(changeset)}
    end
  end

  defp validate_password_confirmation(password, password), do: :ok
  defp validate_password_confirmation(_password, _confirm), do: {:error, :confirmation_mismatch}

  defp changeset_error_message(changeset) do
    changeset.errors
    |> Enum.map_join(", ", fn {field, {message, _opts}} -> "#{field}: #{message}" end)
  end

  defp set_role_from_param(user, role_param) do
    case parse_role(role_param) do
      nil -> {:error, "Unknown role."}
      role -> translate_set_role_result(Accounts.set_role(user, role))
    end
  end

  defp parse_role("user"), do: :user
  defp parse_role("resident"), do: :resident
  defp parse_role("admin"), do: :admin
  defp parse_role(_unknown), do: nil

  defp translate_set_role_result({:ok, user}), do: {:ok, user}

  defp translate_set_role_result({:error, :last_admin}),
    do: {:error, "Cannot remove the last admin."}

  defp translate_set_role_result({:error, %Ecto.Changeset{} = changeset}),
    do: {:error, changeset_error_message(changeset)}

  defp nilify_empty(nil), do: nil
  defp nilify_empty(""), do: nil
  defp nilify_empty(val), do: val

  defp parse_date(nil), do: nil
  defp parse_date(""), do: nil
  defp parse_date(%Date{} = d), do: d

  defp parse_date(str) when is_binary(str) do
    case Date.from_iso8601(str) do
      {:ok, d} -> d
      _ -> nil
    end
  end

  # A request was filed or decided elsewhere (assistant API, another admin tab).
  @impl true
  def handle_info({:change_request, _event, _request}, socket) do
    {:noreply,
     assign(socket,
       pending_requests: ChangeRequests.list_requests(socket.assigns.current_user, :pending),
       existing_overrides: ShiftOverrides.list_all_overrides()
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto py-10 px-4">
      <h1 class="text-2xl font-bold text-gray-800 dark:text-gray-100 mb-8">Admin</h1>

      <div class="space-y-4">
        <%!-- Schedules card --%>
        <div class="border-2 border-gray-200 dark:border-gray-700 rounded-xl overflow-hidden">
          <div class="px-4 py-3 bg-gray-50 dark:bg-gray-950 border-b border-gray-200 dark:border-gray-700">
            <span class="text-xs font-semibold uppercase tracking-widest text-gray-500 dark:text-gray-300">
              Schedules
            </span>
          </div>
          <div class="divide-y divide-gray-100 dark:divide-gray-700">
            <div class="px-4 py-4 flex items-center justify-between">
              <div>
                <p class="text-sm font-medium text-gray-800 dark:text-gray-100">
                  Upload a New Schedule
                </p>
                <p class="text-xs text-gray-500 dark:text-gray-300 mt-0.5">
                  Import a CSV to create a new academic year schedule.
                </p>
              </div>
              <.link
                navigate="/admin/upload"
                class="px-4 py-2 bg-blue-600 text-white text-sm font-medium rounded-lg hover:bg-blue-700 transition-colors shrink-0 ml-4"
              >
                Upload CSV
              </.link>
            </div>

            <%= if @schedules != [] do %>
              <div class="px-4 py-4">
                <div class="flex items-center justify-between mb-3">
                  <div>
                    <p class="text-sm font-medium text-gray-800 dark:text-gray-100">
                      Delete a Schedule
                    </p>
                    <p class="text-xs text-gray-500 dark:text-gray-300 mt-0.5">
                      Permanently removes the schedule and all associated resident and rotation data.
                    </p>
                  </div>
                  <span class="text-xs text-gray-400 dark:text-gray-400 ml-4 shrink-0">
                    {length(@schedules)} schedule{if length(@schedules) != 1, do: "s"}
                  </span>
                </div>
                <ul class="space-y-2">
                  <%= for s <- @schedules do %>
                    <li class="flex items-center justify-between rounded-lg border border-gray-200 dark:border-gray-700 px-3 py-2 bg-white dark:bg-gray-900">
                      <span class="text-sm font-medium text-gray-700 dark:text-gray-200">
                        {s.label}
                      </span>
                      <%= if @delete_confirm_id == s.id do %>
                        <div class="flex items-center gap-2">
                          <span class="text-xs text-red-700 dark:text-red-300 font-medium">
                            Delete {s.label}?
                          </span>
                          <button
                            phx-click="confirm_delete"
                            phx-value-id={s.id}
                            class="px-3 py-1 bg-red-600 text-white text-xs font-medium rounded-md hover:bg-red-700 transition-colors"
                          >
                            Confirm
                          </button>
                          <button
                            phx-click="cancel_delete"
                            class="px-3 py-1 bg-gray-100 dark:bg-gray-800 text-gray-700 dark:text-gray-200 text-xs font-medium rounded-md hover:bg-gray-200 dark:hover:bg-gray-700 transition-colors"
                          >
                            Cancel
                          </button>
                        </div>
                      <% else %>
                        <button
                          phx-click="request_delete"
                          phx-value-id={s.id}
                          class="px-3 py-1 text-xs font-medium text-red-600 dark:text-red-300 border border-red-200 dark:border-red-800 rounded-md hover:bg-red-50 dark:hover:bg-red-950 transition-colors"
                        >
                          Delete
                        </button>
                      <% end %>
                    </li>
                  <% end %>
                </ul>
              </div>
            <% end %>
          </div>
        </div>

        <%!-- Users card --%>
        <div class="border-2 border-gray-200 dark:border-gray-700 rounded-xl overflow-hidden">
          <div class="px-4 py-3 bg-gray-50 dark:bg-gray-950 border-b border-gray-200 dark:border-gray-700">
            <span class="text-xs font-semibold uppercase tracking-widest text-gray-500 dark:text-gray-300">
              Users
            </span>
          </div>

          <%= if @pending_users != [] do %>
            <div class="px-4 py-4">
              <p class="text-sm font-medium text-gray-800 dark:text-gray-100 mb-2">
                Pending Approval ({length(@pending_users)})
              </p>
              <ul class="space-y-2">
                <%= for u <- @pending_users do %>
                  <li class="flex items-center justify-between rounded-lg border border-amber-200 dark:border-amber-800 bg-amber-50 dark:bg-amber-950 px-3 py-2">
                    <div>
                      <span class="text-sm font-medium text-gray-700 dark:text-gray-200">
                        {u.email}
                      </span>
                      <span class="text-xs text-gray-400 dark:text-gray-400 ml-2">
                        {Calendar.strftime(u.inserted_at, "%b %-d, %Y")}
                      </span>
                    </div>
                    <div class="flex items-center gap-2 shrink-0">
                      <button
                        phx-click="approve_user"
                        phx-value-id={u.id}
                        class="px-3 py-1 bg-green-600 text-white text-xs font-medium rounded-md hover:bg-green-700 transition-colors"
                      >
                        Approve
                      </button>
                      <button
                        phx-click="deny_user"
                        phx-value-id={u.id}
                        class="px-3 py-1 text-xs font-medium text-red-600 dark:text-red-300 border border-red-200 dark:border-red-800 rounded-md hover:bg-red-50 dark:hover:bg-red-950 transition-colors"
                      >
                        Deny
                      </button>
                    </div>
                  </li>
                <% end %>
              </ul>
            </div>
          <% end %>

          <div class="px-4 py-4 border-t border-gray-100 dark:border-gray-700">
            <p class="text-sm font-medium text-gray-800 dark:text-gray-100 mb-2">
              Approved Users ({length(@approved_users)})
            </p>
            <%= if @approved_users == [] do %>
              <p class="text-xs text-gray-400 dark:text-gray-400">No approved users yet.</p>
            <% else %>
              <ul class="space-y-2">
                <%= for u <- @approved_users do %>
                  <li class="flex items-center justify-between gap-3 rounded-lg border border-gray-200 dark:border-gray-700 px-3 py-2 bg-white dark:bg-gray-900">
                    <span class="text-sm text-gray-700 dark:text-gray-200 truncate">{u.email}</span>
                    <div class="flex items-center gap-2 shrink-0">
                      <form phx-change="set_role" id={"role-form-#{u.id}"}>
                        <input type="hidden" name="user_id" value={u.id} />
                        <select
                          name="role"
                          class="rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-2 py-1 text-xs text-gray-700 dark:text-gray-200 focus:border-blue-500 focus:outline-none"
                        >
                          <option value="user" selected={u.role == :user}>User</option>
                          <option value="resident" selected={u.role == :resident}>Resident</option>
                          <option value="admin" selected={u.role == :admin}>Admin</option>
                        </select>
                      </form>
                      <button
                        phx-click="revoke_user"
                        phx-value-id={u.id}
                        class="px-3 py-1 text-xs font-medium text-red-600 dark:text-red-300 border border-red-200 dark:border-red-800 rounded-md hover:bg-red-50 dark:hover:bg-red-950 transition-colors"
                      >
                        Revoke
                      </button>
                    </div>
                  </li>
                <% end %>
              </ul>
            <% end %>
            <%= if @role_error do %>
              <p class="text-sm text-red-600 dark:text-red-300 mt-2">{@role_error}</p>
            <% end %>

            <div class="mt-3 pt-3 border-t border-gray-100 dark:border-gray-700">
              <.link
                navigate="/admin/denied"
                class="text-xs text-gray-400 dark:text-gray-400 hover:text-gray-600 dark:hover:text-gray-300"
              >
                Manage denied users →
              </.link>
            </div>
          </div>
        </div>

        <%!-- Account password card --%>
        <div class="border-2 border-gray-200 dark:border-gray-700 rounded-xl overflow-hidden">
          <div class="px-4 py-3 bg-gray-50 dark:bg-gray-950 border-b border-gray-200 dark:border-gray-700">
            <span class="text-xs font-semibold uppercase tracking-widest text-gray-500 dark:text-gray-300">
              My Account
            </span>
          </div>

          <div class="px-4 py-4 space-y-4">
            <div>
              <p class="text-sm font-medium text-gray-800 dark:text-gray-100 mb-0.5">
                {if @has_password, do: "Change My Password", else: "Set My Password"}
              </p>
              <p class="text-xs text-gray-500 dark:text-gray-300">
                Used to log in as {@current_user.email} and to confirm schedule deletion.
              </p>
              <%= unless @has_password do %>
                <p class="text-xs text-amber-600 dark:text-amber-300 mt-1">
                  Your account has no password yet — you can only log in via email link
                  and cannot confirm schedule deletions until you set one.
                </p>
              <% end %>
            </div>

            <form
              id={"account-password-form-#{@password_form_version}"}
              phx-submit="change_password"
              class="space-y-3 max-w-sm"
            >
              <%= if @has_password do %>
                <div>
                  <label class="block text-xs font-medium text-gray-600 dark:text-gray-300 mb-1">
                    Current password
                  </label>
                  <input
                    type="password"
                    name="current_password"
                    autocomplete="current-password"
                    required
                    class="w-full rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-1.5 text-sm text-gray-700 dark:text-gray-200 focus:border-blue-500 focus:outline-none"
                  />
                </div>
              <% end %>

              <div>
                <label class="block text-xs font-medium text-gray-600 dark:text-gray-300 mb-1">
                  New password
                </label>
                <input
                  type="password"
                  name="new_password"
                  autocomplete="new-password"
                  required
                  class="w-full rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-1.5 text-sm text-gray-700 dark:text-gray-200 focus:border-blue-500 focus:outline-none"
                />
                <p class="text-xs text-gray-400 dark:text-gray-400 mt-1">At least 8 characters.</p>
              </div>

              <div>
                <label class="block text-xs font-medium text-gray-600 dark:text-gray-300 mb-1">
                  Confirm new password
                </label>
                <input
                  type="password"
                  name="confirm_password"
                  autocomplete="new-password"
                  required
                  class="w-full rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-1.5 text-sm text-gray-700 dark:text-gray-200 focus:border-blue-500 focus:outline-none"
                />
              </div>

              <%= if @password_error do %>
                <p class="text-sm text-red-600 dark:text-red-300">{@password_error}</p>
              <% end %>
              <%= if @password_success do %>
                <p class="text-sm text-green-600 dark:text-green-300">{@password_success}</p>
              <% end %>

              <button
                type="submit"
                class="px-4 py-2 bg-blue-600 text-white text-sm font-medium rounded-lg hover:bg-blue-700 transition-colors"
              >
                {if @has_password, do: "Update Password", else: "Set Password"}
              </button>
            </form>
          </div>
        </div>

        <%!-- Override card --%>
        <div class="border-2 border-gray-200 dark:border-gray-700 rounded-xl overflow-hidden">
          <div class="px-4 py-3 bg-gray-50 dark:bg-gray-950 border-b border-gray-200 dark:border-gray-700">
            <span class="text-xs font-semibold uppercase tracking-widest text-gray-500 dark:text-gray-300">
              Schedule Overrides
            </span>
          </div>

          <%!-- Pending change requests (filed via the assistant API) --%>
          <%= if @pending_requests != [] or @request_error do %>
            <div class="px-4 py-4 border-b border-gray-200 dark:border-gray-700">
              <p class="text-sm font-medium text-gray-800 dark:text-gray-100 mb-2">
                Pending Change Requests ({length(@pending_requests)})
              </p>
              <%= if @request_error do %>
                <p class="text-sm text-red-600 dark:text-red-300 mb-2">{@request_error}</p>
              <% end %>
              <ul class="space-y-2">
                <%= for r <- @pending_requests do %>
                  <li
                    id={"change-request-#{r.id}"}
                    class="flex items-start justify-between gap-3 rounded-lg border border-amber-200 dark:border-amber-800 bg-amber-50 dark:bg-amber-950 px-3 py-2"
                  >
                    <div class="text-sm text-gray-700 dark:text-gray-200 leading-snug">
                      <span class={"inline-block rounded px-1.5 py-0.5 text-xs font-medium mr-1 #{Rotations.rotation_type_color(r.rotation.rotation_type)}"}>
                        {Rotations.rotation_type_label(r.rotation.rotation_type)}
                      </span>
                      <span class="font-medium">{r.rotation.schedule_resident.name}</span>
                      <span class="text-gray-400 dark:text-gray-400 mx-1">covered by</span>
                      <span class="font-medium">{r.covering_schedule_resident.name}</span>
                      <span class="text-gray-400 dark:text-gray-400 text-xs ml-1">
                        {Calendar.strftime(r.start_date, "%b %-d")}–{Calendar.strftime(
                          r.end_date,
                          "%b %-d, %Y"
                        )}
                      </span>
                      <div class="text-xs text-gray-500 dark:text-gray-300 mt-0.5">
                        Requested by {r.requested_by_user.email} on {Calendar.strftime(
                          r.inserted_at,
                          "%b %-d, %Y"
                        )}
                        <%= if r.note do %>
                          <span class="text-gray-400 dark:text-gray-400">·</span> “{r.note}”
                        <% end %>
                      </div>
                    </div>
                    <div class="flex items-center gap-2 shrink-0">
                      <button
                        phx-click="approve_request"
                        phx-value-id={r.id}
                        class="rounded-md bg-green-600 px-2.5 py-1 text-xs font-medium text-white hover:bg-green-700"
                      >
                        Approve
                      </button>
                      <button
                        phx-click="deny_request"
                        phx-value-id={r.id}
                        class="rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-2.5 py-1 text-xs font-medium text-gray-700 dark:text-gray-200 hover:bg-gray-50 dark:hover:bg-gray-950"
                      >
                        Deny
                      </button>
                    </div>
                  </li>
                <% end %>
              </ul>
            </div>
          <% end %>

          <div class="px-4 py-4 space-y-4">
            <div>
              <p class="text-sm font-medium text-gray-800 dark:text-gray-100 mb-0.5">
                Create a Shift Override
              </p>
              <p class="text-xs text-gray-500 dark:text-gray-300">
                Assign a resident to cover another's shift for a specific date range.
              </p>
            </div>

            <form phx-change="override_change" phx-submit="save_override" class="space-y-3">
              <%!-- Step 1: shift type + date range --%>
              <div class="grid grid-cols-1 sm:grid-cols-3 gap-3">
                <div>
                  <label class="block text-xs font-medium text-gray-600 dark:text-gray-300 mb-1">
                    Shift type
                  </label>
                  <select
                    name="rotation_type"
                    class="w-full rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-1.5 text-sm text-gray-700 dark:text-gray-200 focus:border-blue-500 focus:outline-none"
                  >
                    <option value="">— select —</option>
                    <%= for type <- Rotations.all_rotation_types() |> Enum.sort() do %>
                      <option value={type} selected={@override_rotation_type == type}>
                        {Rotations.rotation_type_label(type)}
                      </option>
                    <% end %>
                  </select>
                </div>

                <div>
                  <label class="block text-xs font-medium text-gray-600 dark:text-gray-300 mb-1">
                    From
                  </label>
                  <input
                    type="date"
                    name="start_date"
                    value={date_value(@override_start_date)}
                    class="w-full rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-1.5 text-sm text-gray-700 dark:text-gray-200 focus:border-blue-500 focus:outline-none"
                  />
                </div>

                <div>
                  <label class="block text-xs font-medium text-gray-600 dark:text-gray-300 mb-1">
                    To
                  </label>
                  <input
                    type="date"
                    name="end_date"
                    value={date_value(@override_end_date)}
                    class="w-full rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-1.5 text-sm text-gray-700 dark:text-gray-200 focus:border-blue-500 focus:outline-none"
                  />
                </div>
              </div>

              <%!-- Step 2: select which rotation to override --%>
              <div class={
                if @available_rotations == [], do: "opacity-40 pointer-events-none", else: ""
              }>
                <label class="block text-xs font-medium text-gray-600 dark:text-gray-300 mb-1">
                  Resident to cover for
                  <%= if @available_rotations == [] do %>
                    <span class="text-gray-400 dark:text-gray-400 font-normal">
                      (select shift type and dates first)
                    </span>
                  <% end %>
                </label>
                <select
                  name="rotation_id"
                  class="w-full rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-1.5 text-sm text-gray-700 dark:text-gray-200 focus:border-blue-500 focus:outline-none"
                >
                  <option value="">— select resident —</option>
                  <%= for rot <- @available_rotations do %>
                    <option
                      value={rot.id}
                      selected={to_string(rot.id) == to_string(@override_rotation_id)}
                    >
                      {rot.schedule_resident.name} ({rot.schedule_resident.position_code}) — {Calendar.strftime(
                        rot.start_date,
                        "%b %-d"
                      )} – {Calendar.strftime(rot.end_date, "%b %-d, %Y")}
                    </option>
                  <% end %>
                </select>
              </div>

              <%!-- Step 3: select covering resident --%>
              <div class={
                if @override_rotation_id in [nil, ""], do: "opacity-40 pointer-events-none", else: ""
              }>
                <label class="block text-xs font-medium text-gray-600 dark:text-gray-300 mb-1">
                  Covering resident
                  <%= if @override_rotation_id in [nil, ""] do %>
                    <span class="text-gray-400 dark:text-gray-400 font-normal">
                      (select resident to cover for first)
                    </span>
                  <% end %>
                </label>
                <select
                  name="covering_resident_id"
                  class="w-full rounded-md border border-gray-300 dark:border-gray-600 bg-white dark:bg-gray-900 px-3 py-1.5 text-sm text-gray-700 dark:text-gray-200 focus:border-blue-500 focus:outline-none"
                >
                  <option value="">— select covering resident —</option>
                  <%= for res <- @available_covering_residents do %>
                    <option
                      value={res.id}
                      selected={to_string(res.id) == to_string(@override_covering_resident_id)}
                    >
                      {res.name} ({res.position_code})
                    </option>
                  <% end %>
                </select>
              </div>

              <%= if @override_error do %>
                <p class="text-sm text-red-600 dark:text-red-300">{@override_error}</p>
              <% end %>
              <%= if @override_success do %>
                <p class="text-sm text-green-600 dark:text-green-300">{@override_success}</p>
              <% end %>

              <button
                type="submit"
                class="px-4 py-2 bg-blue-600 text-white text-sm font-medium rounded-lg hover:bg-blue-700 transition-colors"
              >
                Save Override
              </button>
            </form>
          </div>

          <%!-- Existing overrides list --%>
          <%= if @existing_overrides != [] do %>
            <div class="border-t border-gray-200 dark:border-gray-700">
              <div class="px-4 py-3 bg-gray-50 dark:bg-gray-950 border-b border-gray-100 dark:border-gray-700">
                <span class="text-xs font-semibold uppercase tracking-widest text-gray-500 dark:text-gray-300">
                  Active Overrides ({length(@existing_overrides)})
                </span>
              </div>
              <ul class="divide-y divide-gray-100 dark:divide-gray-700">
                <%= for o <- @existing_overrides do %>
                  <li class="px-4 py-3 flex items-start justify-between gap-3">
                    <div class="text-sm text-gray-700 dark:text-gray-200 leading-snug">
                      <span class={"inline-block rounded px-1.5 py-0.5 text-xs font-medium mr-1 #{Rotations.rotation_type_color(o.rotation.rotation_type)}"}>
                        {Rotations.rotation_type_label(o.rotation.rotation_type)}
                      </span>
                      <span class="font-medium">{o.rotation.schedule_resident.name}</span>
                      <span class="text-gray-400 dark:text-gray-400 mx-1">covered by</span>
                      <span class="font-medium">{o.covering_schedule_resident.name}</span>
                      <span class="text-gray-400 dark:text-gray-400 text-xs ml-1">
                        {Calendar.strftime(o.override_start_date, "%b %-d")}–{Calendar.strftime(
                          o.override_end_date,
                          "%b %-d, %Y"
                        )}
                      </span>
                    </div>
                    <button
                      phx-click="delete_override"
                      phx-value-id={o.id}
                      class="text-xs text-red-500 dark:text-red-300 hover:text-red-700 dark:hover:text-red-300 shrink-0 mt-0.5"
                    >
                      Remove
                    </button>
                  </li>
                <% end %>
              </ul>
            </div>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  defp refresh_requests(result, socket) do
    error =
      case result do
        {:ok, _request} -> nil
        {:error, :not_pending} -> "That request was already decided."
        {:error, :not_found} -> "That request no longer exists."
        {:error, _other} -> "The request could not be updated."
      end

    {:noreply,
     assign(socket,
       pending_requests: ChangeRequests.list_requests(socket.assigns.current_user, :pending),
       existing_overrides: ShiftOverrides.list_all_overrides(),
       request_error: error
     )}
  end

  defp date_value(nil), do: ""
  defp date_value(%Date{} = d), do: Date.to_iso8601(d)
  defp date_value(_), do: ""

  defp format_changeset_errors(changeset) do
    Enum.map_join(changeset.errors, ", ", fn {field, {message, _}} -> "#{field}: #{message}" end)
  end
end
