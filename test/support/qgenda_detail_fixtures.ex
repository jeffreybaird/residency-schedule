defmodule ResidencySchedule.QgendaDetailFixtures do
  @moduledoc "Synthetic roster and workbook helpers for QGenda detail persistence."
  alias ResidencySchedule.Importer.QgendaPreview
  alias ResidencySchedule.{Residents, Rotations, Schedules}

  def seed_detail_roster do
    {:ok, schedule} = Schedules.upsert_schedule(2026, "2026–2027")

    people =
      for {name, number} <- [{"Iris Reed", 1}, {"Juniper Vail", 2}, {"Iris Stone", 3}] do
        {:ok, person} =
          Residents.insert_resident(schedule.id, %{
            name: name,
            position_code: "R2-#{number}",
            residency_year: 2,
            schedule_number: number
          })

        person
      end

    [iris, juniper, stone] = people

    {:ok, _} =
      Rotations.insert_rotations(iris.id, [
        %{
          slot_index: 0,
          start_date: ~D[2026-12-28],
          end_date: ~D[2027-01-03],
          rotation_type: :strong_gynecology
        }
      ])

    %{schedule: schedule, iris: iris, juniper: juniper, stone: stone}
  end

  def detail_preview(binary \\ detail_workbook()) do
    QgendaPreview.prepare(binary,
      academic_year: 2026,
      aliases: %{
        "Vale, Juniper" => %{position_code: "R2-2", expected_name: "Juniper Vail"}
      }
    )
  end

  def detail_workbook, do: File.read!("test/fixtures/qgenda/shared.xlsx")

  def mutate_detail_workbook(path, fun) do
    {:ok, entries} = :zip.extract(detail_workbook(), [:memory])

    entries =
      Enum.map(entries, fn {name, binary} ->
        {name, if(to_string(name) == path, do: fun.(binary), else: binary)}
      end)

    {:ok, {_, binary}} = :zip.create(~c"detail.xlsx", entries, [:memory])
    binary
  end
end
