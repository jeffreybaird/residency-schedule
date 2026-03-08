defmodule ResidencyScheduleWeb.PageController do
  use ResidencyScheduleWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
