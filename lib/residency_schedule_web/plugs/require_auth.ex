defmodule ResidencyScheduleWeb.Plugs.RequireAuth do
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  alias ResidencySchedule.Accounts

  def init(opts), do: opts

  def call(conn, _opts) do
    user_id = get_session(conn, :user_id)

    with id when not is_nil(id) <- user_id,
         %Accounts.User{approved: true} = user <- Accounts.get_user(id) do
      assign(conn, :current_user, user)
    else
      _ ->
        conn
        |> redirect(to: "/login")
        |> halt()
    end
  end
end
