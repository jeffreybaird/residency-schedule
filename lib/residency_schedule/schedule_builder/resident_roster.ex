defmodule ResidencySchedule.ScheduleBuilder.ResidentRoster do
  @moduledoc """
  Generates the resident roster template for a new schedule.

  Produces placeholder residents (R1-1 through R4-8) with per-year
  rotation target counts derived from the 2025–2026 schedule baseline.

  Note: USN and US are both abbreviations for Ultrasound. USN was the older
  designation used before 2025–2026; US is the current form. Both parse to
  the same :ultrasound atom. Historical schedules contain USN entries.
  """

  @years [1, 2, 3, 4]

  # Targets are median per-resident per-year slot counts derived from
  # analysis of the 2023-2024, 2024-2025, and 2025-2026 historical schedules.
  # Each year level has its own set of applicable rotations — rotations not listed
  # here are not valid for that year (e.g. US is R1-only, UG is R3-only,
  # HHOB/REI are R2-only). Elective applies to R3 and R4.
  @rotation_targets %{
    1 => %{
      strong_obstetrics: 6,
      oncology: 6,
      strong_gynecology: 6,
      highland_gynecology: 7,
      highland_night_float: 2,
      highland_weekend_days: 4,
      highland_weekend_nights: 3,
      ambulatory: 6,
      night_float: 6,
      vacation: 4,
      swing: 2,
      strong_weekend_days: 6,
      strong_weekend_nights: 6,
      # US (ultrasound) is an R1-only rotation introduced in 2025-2026
      ultrasound: 3
    },
    2 => %{
      strong_obstetrics: 6,
      oncology: 6,
      strong_gynecology: 6,
      highland_gynecology: 2,
      highland_obstetrics: 6,
      highland_night_float: 2,
      highland_weekend_days: 5,
      highland_weekend_nights: 3,
      ambulatory: 6,
      night_float: 6,
      vacation: 4,
      rei: 4,
      strong_weekend_days: 6,
      strong_weekend_nights: 6
    },
    3 => %{
      strong_obstetrics: 6,
      oncology: 6,
      strong_gynecology: 6,
      highland_gynecology: 3,
      highland_night_float: 3,
      highland_weekend_days: 3,
      highland_weekend_nights: 3,
      ambulatory: 6,
      night_float: 6,
      vacation: 4,
      elective: 4,
      urogynecology: 4,
      strong_weekend_days: 6,
      strong_weekend_nights: 6
    },
    4 => %{
      strong_obstetrics: 6,
      oncology: 6,
      strong_gynecology: 6,
      highland_gynecology: 6,
      highland_night_float: 3,
      highland_weekend_days: 3,
      highland_weekend_nights: 3,
      ambulatory: 6,
      night_float: 6,
      vacation: 4,
      elective: 4,
      # Swing appears in ~70% of R4 resident-years
      swing: 1,
      strong_weekend_days: 6,
      strong_weekend_nights: 6
    }
  }

  @doc """
  Builds the resident template list for a new schedule year.

  Returns a list of resident maps ordered by residency_year then schedule_number,
  with placeholder names (e.g. "R1-1").

      iex> residents = ResidencySchedule.ScheduleBuilder.ResidentRoster.build_residents()
      iex> length(residents)
      32
      iex> hd(residents).position_code
      "R1-1"
      iex> List.last(residents).position_code
      "R4-8"
  """
  def build_residents(count_per_year \\ 8) do
    for year <- @years, num <- 1..count_per_year do
      %{
        position_code: "R#{year}-#{num}",
        residency_year: year,
        schedule_number: num,
        name: "R#{year}-#{num}"
      }
    end
  end

  @doc """
  Returns the rotation target counts for a given residency year.

  These are the approximate number of each rotation type a resident at
  that year level should receive over the academic year.

      iex> targets = ResidencySchedule.ScheduleBuilder.ResidentRoster.rotation_targets_for_year(2)
      iex> Map.fetch!(targets, :highland_obstetrics)
      6
      iex> Map.has_key?(targets, :rei)
      true
  """
  def rotation_targets_for_year(residency_year) do
    Map.fetch!(@rotation_targets, residency_year)
  end

  @doc """
  Returns a list of rotation types that are valid for a given residency year.

  Excludes rotations that belong only to other year levels. USN has been
  removed as of the 2025–2026 schedule and is no longer a valid option.

      iex> types = ResidencySchedule.ScheduleBuilder.ResidentRoster.valid_rotations_for_year(1)
      iex> :unknown in types
      false
      iex> :highland_obstetrics in types
      false
  """
  def valid_rotations_for_year(residency_year) do
    rotation_targets_for_year(residency_year)
    |> Map.keys()
    |> Enum.sort()
  end

  @weekday_only_rotations ~w(
    strong_obstetrics oncology strong_gynecology ambulatory night_float
    highland_obstetrics highland_gynecology highland_night_float
    rei urogynecology elective swing ultrasound vacation
  )a

  @weekend_only_rotations ~w(
    strong_weekend_days strong_weekend_nights highland_weekend_days highland_weekend_nights
  )a

  @doc """
  Returns the rotation types valid for a given residency year filtered by slot type.

  FLOAT slots (7-day Mon–Sun span) only permit :float. Weekend slots exclude
  weekday-only clinical rotations. Weekday slots exclude weekend-only rotations.

      iex> slot = %{is_weekend: true, start_date: ~D[2026-07-04], end_date: ~D[2026-07-05]}
      iex> types = ResidencySchedule.ScheduleBuilder.ResidentRoster.valid_rotations_for_slot(1, slot)
      iex> :strong_weekend_days in types
      true
      iex> :strong_obstetrics in types
      false
  """
  def valid_rotations_for_slot(residency_year, slot) do
    cond do
      float_slot?(slot) ->
        [:float]

      slot.is_weekend ->
        residency_year
        |> valid_rotations_for_year()
        |> Enum.reject(&(&1 in @weekday_only_rotations))

      true ->
        residency_year
        |> valid_rotations_for_year()
        |> Enum.reject(&(&1 in @weekend_only_rotations))
    end
  end

  # --- Private ---

  defp float_slot?(slot) do
    not slot.is_weekend and Date.diff(slot.end_date, slot.start_date) == 6
  end
end
