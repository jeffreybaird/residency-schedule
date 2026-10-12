defmodule ResidencySchedule.DetailedSchedules.TaskEquivalence do
  @moduledoc "Reviewed exact task names that describe an existing rotation."

  @equivalents %{
    "Ambulatory R1" => ["ambulatory"],
    "Ambulatory R2" => ["ambulatory"],
    "Ambulatory R3" => ["ambulatory"],
    "Ambulatory R4" => ["ambulatory"],
    "Elective R3" => ["elective"],
    "Elective R4" => ["elective"],
    "HH GYN ONC R1" => ["oncology"],
    "HH GYN ONC R2" => ["oncology"],
    "HH GYN ONC R3" => ["oncology"],
    "HH GYN ONC R4" => ["oncology"],
    "HH GYN R1" => ["highland_gynecology"],
    "HH GYN R2" => ["highland_gynecology"],
    "HH GYN R3" => ["highland_gynecology"],
    "HH GYN R4" => ["highland_gynecology"],
    "HH Weekend 2nd Call" => ["highland_weekend_days"],
    "HH Weekend 3rd Call" => ["highland_weekend_days"],
    "HH Weekend Extra" => ["highland_weekend_days"],
    "HH Nights 2nd Call" => ["highland_weekend_nights", "highland_night_float"],
    "HH Nights 3rd Call" => ["highland_weekend_nights", "highland_night_float"],
    "HH Nights Extra" => ["highland_weekend_nights", "highland_night_float"],
    "REI Resident" => ["rei"],
    "Swing Resident" => ["swing"],
    "Urogyn Resident" => ["urogynecology"],
    "Ultrasound" => ["ultrasound"],
    "Vacation" => ["vacation"],
    "Post-Call" => ["post_call"],
    "SMH GYN R2 Day" => ["strong_gynecology"],
    "SMH GYN R3 Day" => ["strong_gynecology"],
    "SMH Gynecology Chief On Call Day" => ["strong_gynecology", "strong_weekend_days"],
    "SMH Gynecology Intern On Call Day" => ["strong_gynecology", "strong_weekend_days"],
    "SMH Gynecology Chief On Call Night" => ["night_float", "strong_weekend_nights"],
    "SMH Gynecology Intern On Call Night" => ["night_float", "strong_weekend_nights"],
    "SMH Obstetrics Resident 1st Contact Day" => ["strong_obstetrics", "strong_weekend_days"],
    "SMH Obstetrics Resident 2nd Contact Day" => ["strong_obstetrics", "strong_weekend_days"],
    "SMH Obstetrics Resident 3rd Contact Day" => ["strong_obstetrics", "strong_weekend_days"],
    "SMH Obstetrics Resident 4th Contact Day" => ["strong_obstetrics", "strong_weekend_days"],
    "SMH Obstetrics Resident 1st Contact Night" => ["night_float", "strong_weekend_nights"],
    "SMH Obstetrics Resident 2nd Contact Night" => ["night_float", "strong_weekend_nights"],
    "SMH Obstetrics Resident 3rd Contact Night" => ["night_float", "strong_weekend_nights"],
    "SMH Obstetrics Resident 4th Contact Night" => ["night_float", "strong_weekend_nights"]
  }

  @doc """
  Checks whether an exact imported task describes the supplied rotation type.

      iex> ResidencySchedule.DetailedSchedules.TaskEquivalence.matches_rotation?("SMH GYN R2 Day", "strong_gynecology")
      true

      iex> ResidencySchedule.DetailedSchedules.TaskEquivalence.matches_rotation?("HH Nights 3rd Call", "highland_night_float")
      true

      iex> ResidencySchedule.DetailedSchedules.TaskEquivalence.matches_rotation?("HH Nights 3rd Call", "highland_weekend_days")
      false

      iex> ResidencySchedule.DetailedSchedules.TaskEquivalence.matches_rotation?("Unreviewed task", nil)
      false
  """
  def matches_rotation?(task, type), do: type in Map.get(@equivalents, task, [])
end
