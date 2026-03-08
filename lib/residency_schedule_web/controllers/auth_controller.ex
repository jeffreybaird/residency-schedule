defmodule ResidencyScheduleWeb.AuthController do
  use ResidencyScheduleWeb, :controller

  def show(conn, _params) do
    render(conn, :show)
  end

  def create(conn, %{"password" => password}) do
    expected = Application.fetch_env!(:residency_schedule, :access_password)

    if Plug.Crypto.secure_compare(password, expected) do
      conn
      |> put_session(:authenticated, true)
      |> redirect(to: "/")
    else
      conn
      |> put_flash(:error, "Incorrect password.")
      |> render(:show)
    end
  end

  def delete(conn, _params) do
    conn
    |> delete_session(:authenticated)
    |> redirect(to: "/login")
  end
end
