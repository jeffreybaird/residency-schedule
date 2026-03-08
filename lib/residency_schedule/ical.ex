defmodule ResidencySchedule.Ical do
  alias ResidencySchedule.Rotations

  @doc """
  Builds an iCal (VCALENDAR) string for a resident's full schedule.

      iex> resident = %{name: "Test", rotations: []}
      iex> result = ResidencySchedule.Ical.build(resident)
      iex> String.contains?(result, "BEGIN:VCALENDAR")
      true
  """
  def build(resident) do
    events = Enum.map(resident.rotations, &build_event(resident, &1))

    """
    BEGIN:VCALENDAR
    VERSION:2.0
    PRODID:-//ResidencySchedule//EN
    CALSCALE:GREGORIAN
    X-WR-CALNAME:#{resident.name} – Schedule
    #{Enum.join(events, "")}END:VCALENDAR
    """
  end

  defp build_event(resident, rotation) do
    uid = "rotation-#{rotation.id}@residency-schedule"
    label = Rotations.rotation_type_label(rotation.rotation_type)
    dtstart = Calendar.strftime(rotation.start_date, "%Y%m%d")
    dtend = rotation.end_date |> Date.add(1) |> Calendar.strftime("%Y%m%d")

    """
    BEGIN:VEVENT
    UID:#{uid}
    SUMMARY:#{label}
    DTSTART;VALUE=DATE:#{dtstart}
    DTEND;VALUE=DATE:#{dtend}
    DESCRIPTION:#{resident.name} – #{label}
    END:VEVENT
    """
  end
end
