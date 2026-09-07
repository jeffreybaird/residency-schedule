defmodule ResidencyScheduleWeb.IcalController do
  use ResidencyScheduleWeb, :controller

  alias ResidencySchedule.Residents
  alias ResidencySchedule.Ical

  def show(conn, %{"id" => id}) do
    resident = Residents.get_resident!(String.to_integer(id))
    send_ical(conn, Ical.build(resident), resident.name)
  end

  def feed(conn, %{"token" => token}) do
    person = Residents.get_person_by_token!(token)
    send_ical(conn, Ical.build_for_person(person), person.name)
  end

  defp send_ical(conn, ical, name) do
    conn
    |> put_resp_content_type("text/calendar")
    |> put_resp_header(
      "content-disposition",
      ~s(attachment; filename="#{name}.ics")
    )
    |> send_resp(200, ical)
  end
end
