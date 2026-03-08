defmodule ResidencyScheduleWeb.IcalController do
  use ResidencyScheduleWeb, :controller

  alias ResidencySchedule.Residents
  alias ResidencySchedule.Ical

  def show(conn, %{"id" => id}) do
    resident = Residents.get_resident!(String.to_integer(id))
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
