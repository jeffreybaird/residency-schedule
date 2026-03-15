defmodule ResidencyScheduleWeb.AuthController do
  use ResidencyScheduleWeb, :controller

  alias ResidencySchedule.Residents

  # ── Site login ────────────────────────────────────────────────────────────

  def show(conn, _params) do
    render(conn, :show)
  end

  def create(conn, %{"password" => password}) do
    site_password = Application.fetch_env!(:residency_schedule, :access_password)

    cond do
      Plug.Crypto.secure_compare(password, site_password) ->
        conn
        |> put_session(:authenticated, true)
        |> delete_session(:resident_id)
        |> redirect(to: "/")

      resident = Residents.find_by_password(password) ->
        conn
        |> put_session(:authenticated, true)
        |> put_session(:resident_id, resident.id)
        |> redirect(to: "/residents/#{resident.id}")

      true ->
        conn
        |> put_flash(:error, "Incorrect password.")
        |> render(:show)
    end
  end

  def delete(conn, _params) do
    conn
    |> delete_session(:authenticated)
    |> delete_session(:resident_id)
    |> delete_session(:admin)
    |> redirect(to: "/login")
  end

  def set_home(conn, %{"resident_id" => id}) do
    conn
    |> put_session(:resident_id, String.to_integer(id))
    |> redirect(to: "/residents/#{id}")
  end

  def unset_home(conn, %{"resident_id" => id}) do
    conn
    |> delete_session(:resident_id)
    |> redirect(to: "/residents/#{id}")
  end

  # ── Admin login ───────────────────────────────────────────────────────────

  def admin_show(conn, _params) do
    render(conn, :admin_login)
  end

  def admin_create(conn, %{"password" => password}) do
    admin_password = Application.fetch_env!(:residency_schedule, :delete_password)

    if password == admin_password do
      conn
      |> put_session(:authenticated, true)
      |> put_session(:admin, true)
      |> redirect(to: "/admin")
    else
      conn
      |> put_flash(:error, "Incorrect admin password.")
      |> render(:admin_login)
    end
  end

  def admin_delete(conn, _params) do
    conn
    |> delete_session(:admin)
    |> redirect(to: "/admin/login")
  end
end
