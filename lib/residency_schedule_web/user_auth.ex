defmodule ResidencyScheduleWeb.UserAuth do
  @moduledoc """
  LiveView `on_mount` hooks that enforce authentication and role checks.

  Router plugs only guard the initial HTTP request; live navigation within a
  `live_session` never passes through them. These hooks re-check the session
  on every mount (disconnected and connected) so role checks hold across
  live redirects too.
  """

  import Phoenix.Component, only: [assign: 3]
  import Phoenix.LiveView, only: [redirect: 2]

  alias ResidencySchedule.Accounts
  alias ResidencySchedule.Accounts.User

  @doc """
  `on_mount` hook. `:ensure_authenticated` requires an approved user of any
  role and assigns `:current_user`; `:ensure_admin` additionally requires the
  admin role. Unauthenticated mounts redirect to /login; authenticated
  non-admins hitting `:ensure_admin` redirect to /.

  Exempt from doctest — loads the user from the database.
  """
  def on_mount(:ensure_authenticated, _params, session, socket) do
    case load_approved_user(session) do
      %User{} = user -> {:cont, assign(socket, :current_user, user)}
      nil -> {:halt, redirect(socket, to: "/login")}
    end
  end

  def on_mount(:ensure_admin, _params, session, socket) do
    case load_approved_user(session) do
      %User{role: :admin} = user -> {:cont, assign(socket, :current_user, user)}
      %User{} -> {:halt, redirect(socket, to: "/")}
      nil -> {:halt, redirect(socket, to: "/login")}
    end
  end

  defp load_approved_user(session) do
    with user_id when not is_nil(user_id) <- session["user_id"],
         %User{approved: true} = user <- Accounts.get_user(user_id) do
      user
    else
      _ -> nil
    end
  end
end
