defmodule ResidencySchedule.ResidentPerformanceFixtures do
  @moduledoc false
  alias ResidencySchedule.{Residents, Rotations, Schedules}

  def four_year_career(name \\ "Synthetic Career") do
    Enum.map_reduce(2023..2026, nil, fn year, person_id ->
      {:ok, schedule} = Schedules.upsert_schedule(year, "#{year}–#{year + 1}")
      attrs = %{name: name, position_code: "R2-1", residency_year: 2, schedule_number: 1}
      attrs = if person_id, do: Map.put(attrs, :resident_id, person_id), else: attrs
      {:ok, resident} = Residents.insert_resident(schedule.id, attrs)

      {:ok, _} =
        Rotations.insert_rotations(resident.id, [
          %{
            rotation_type: :strong_obstetrics,
            slot_index: 0,
            start_date: Date.new!(year, 7, 1),
            end_date: Date.new!(year, 7, 7)
          },
          %{
            rotation_type: :night_float,
            slot_index: 1,
            start_date: Date.new!(year, 7, 8),
            end_date: Date.new!(year, 7, 14)
          },
          %{
            rotation_type: :vacation,
            slot_index: 2,
            start_date: Date.new!(year, 7, 15),
            end_date: Date.new!(year, 7, 21)
          }
        ])

      {Residents.get_resident!(resident.id), resident.resident_id}
    end)
    |> elem(0)
  end
end
