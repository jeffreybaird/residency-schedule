defmodule ResidencyScheduleWeb.AdminLive.Denied do
  use ResidencyScheduleWeb, :live_view

  on_mount {ResidencyScheduleWeb.UserAuth, :ensure_admin}

  alias ResidencySchedule.Accounts

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       denied_users: Accounts.list_denied_users(),
       reinstate_error: nil
     )}
  end

  @impl true
  def handle_event("reinstate_user", %{"id" => id}, socket) do
    user = Accounts.get_user!(String.to_integer(id))

    case Accounts.reinstate_user(user) do
      {:ok, _user} ->
        {:noreply,
         assign(socket, denied_users: Accounts.list_denied_users(), reinstate_error: nil)}

      {:error, _changeset} ->
        {:noreply, assign(socket, reinstate_error: "Could not reinstate this user.")}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="max-w-2xl mx-auto py-10 px-4">
      <div class="flex items-center justify-between mb-8">
        <h1 class="text-2xl font-bold text-gray-800">Denied Users</h1>
        <.link navigate="/admin" class="text-sm text-gray-400 hover:text-gray-600">
          ← Back to Admin
        </.link>
      </div>

      <div class="border-2 border-gray-200 rounded-xl overflow-hidden">
        <div class="px-4 py-3 bg-gray-50 border-b border-gray-200">
          <span class="text-xs font-semibold uppercase tracking-widest text-gray-500">
            Denied ({length(@denied_users)})
          </span>
        </div>

        <div class="px-4 py-4">
          <p class="text-xs text-gray-500 mb-3">
            These accounts were denied approval. Allowing one to try again returns it to
            the pending list so you can approve it later.
          </p>

          <%= if @denied_users == [] do %>
            <p class="text-xs text-gray-400">No denied users.</p>
          <% else %>
            <ul class="space-y-2">
              <%= for u <- @denied_users do %>
                <li class="flex items-center justify-between rounded-lg border border-gray-200 bg-white px-3 py-2">
                  <div>
                    <span class="text-sm font-medium text-gray-700">{u.email}</span>
                    <span class="text-xs text-gray-400 ml-2">
                      {Calendar.strftime(u.inserted_at, "%b %-d, %Y")}
                    </span>
                  </div>
                  <button
                    phx-click="reinstate_user"
                    phx-value-id={u.id}
                    class="px-3 py-1 text-xs font-medium text-blue-600 border border-blue-200 rounded-md hover:bg-blue-50 transition-colors"
                  >
                    Allow to try again
                  </button>
                </li>
              <% end %>
            </ul>
          <% end %>

          <%= if @reinstate_error do %>
            <p class="text-sm text-red-600 mt-2">{@reinstate_error}</p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end
end
