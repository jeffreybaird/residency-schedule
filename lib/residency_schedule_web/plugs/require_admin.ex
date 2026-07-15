defmodule ResidencyScheduleWeb.Plugs.RequireAdmin do
  @moduledoc """
  Allows the request only for approved users with the admin role, assigning
  `:current_user`. Approved non-admins are redirected to the site root;
  everyone else to /login.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias ResidencySchedule.Accounts
  alias ResidencySchedule.Accounts.User

  @doc """
  Plug options are passed through unchanged.

      iex> ResidencyScheduleWeb.Plugs.RequireAdmin.init([])
      []
  """
  def init(opts), do: opts

  @doc """
  Enforces the admin role for the request.

  Exempt from doctest — loads the user from the database.
  """
  def call(conn, _opts) do
    with user_id when not is_nil(user_id) <- get_session(conn, :user_id),
         %User{approved: true, role: :admin} = user <- Accounts.get_user(user_id) do
      assign(conn, :current_user, user)
    else
      %User{approved: true} ->
        conn
        |> redirect(to: "/")
        |> halt()

      _ ->
        conn
        |> redirect(to: "/login")
        |> halt()
    end
  end
end
