defmodule ResidencyScheduleWeb.Plugs.RequireAuthOrAdmin do
  @moduledoc """
  Allows the browser pipeline to continue when the visitor is either:

  - logged in as **admin** (`:admin` session flag), or
  - an **approved resident user** (same rules as `RequireAuth`).

  Admin sessions do not set `:user_id`; those requests have no `current_user` assign.
  """

  import Plug.Conn

  alias ResidencyScheduleWeb.Plugs.RequireAuth

  @doc """
  Plug options are passed through to `RequireAuth` when the session is not admin.

      iex> ResidencyScheduleWeb.Plugs.RequireAuthOrAdmin.init([])
      []
  """
  def init(opts), do: opts

  @doc """
  Allows the request when the session has `:admin`, otherwise enforces `RequireAuth`.

  Doctest omitted: the non-admin path loads the user from the database; see ExUnit tests.
  """
  def call(conn, opts) do
    if get_session(conn, :admin) do
      conn
    else
      RequireAuth.call(conn, opts)
    end
  end
end
