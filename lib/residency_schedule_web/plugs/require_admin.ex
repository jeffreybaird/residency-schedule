defmodule ResidencyScheduleWeb.Plugs.RequireAdmin do
  import Plug.Conn
  import Phoenix.Controller, only: [redirect: 2]

  def init(opts), do: opts

  def call(conn, _opts) do
    if get_session(conn, :admin) do
      conn
    else
      conn
      |> redirect(to: "/admin/login")
      |> halt()
    end
  end
end
