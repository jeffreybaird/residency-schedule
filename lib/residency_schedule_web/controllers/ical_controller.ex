defmodule ResidencyScheduleWeb.IcalController do
  use ResidencyScheduleWeb, :controller

  alias ResidencySchedule.Residents
  alias ResidencySchedule.Ical

  def show(conn, %{"id" => id}) do
    resident = Residents.get_resident!(String.to_integer(id))
    send_ical(conn, resident)
  end

  def feed(conn, %{"token" => token}) do
    resident = Residents.get_resident_by_token!(token)
    send_ical(conn, resident)
  end

  defp send_ical(conn, resident) do
    ical = Ical.build(resident)

    conn
    |> put_resp_content_type("text/calendar")
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="#{resident.name}.ics")
    )
    |> send_resp(200, ical)
  end
end
