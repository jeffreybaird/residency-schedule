defmodule ResidencySchedule.EffectiveSchedule.Calendar do
  @moduledoc "Calendar identities for retained dated duties, independent of baseline segments."

  @doc """
  Emits a date-only event without inventing clock hours.

      iex> entry = %{activity_id: 3, source_id: 4, date: ~D[2026-11-03], duty: %{label: "Ultrasound", timing: %{precision: :period, period: "AM"}}}
      iex> event = ResidencySchedule.EffectiveSchedule.Calendar.event(entry)
      iex> {event.dtstart, event.dtend, event.summary}
      {"20261103", "20261104", "Ultrasound"}
  """
  def event(entry) do
    {first, last} = times(entry.date, entry.duty.timing)

    %{
      uid:
        "activity-#{entry.activity_id}-source-#{entry.source_id || "missing"}@residency-schedule",
      dtstart: first,
      dtend: last,
      summary: escape(entry.duty.label)
    }
  end

  defp times(_date, %{precision: :exact, starts_at: first, ends_at: last}),
    do: {Calendar.strftime(first, "%Y%m%dT%H%M%SZ"), Calendar.strftime(last, "%Y%m%dT%H%M%SZ")}

  defp times(date, _),
    do: {Calendar.strftime(date, "%Y%m%d"), Calendar.strftime(Date.add(date, 1), "%Y%m%d")}

  defp escape(value),
    do:
      value
      |> String.replace("\\", "\\\\")
      |> String.replace("\n", "\\n")
      |> String.replace(",", "\\,")
      |> String.replace(";", "\\;")
end
