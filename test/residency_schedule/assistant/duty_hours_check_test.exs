defmodule ResidencySchedule.Assistant.DutyHoursCheckTest do
  use ResidencySchedule.DataCase, async: true

  import ResidencySchedule.ScheduleFixtures

  alias ResidencySchedule.Assistant.DutyHoursCheck
  alias ResidencySchedule.{Rotations, ShiftOverrides}

  doctest DutyHoursCheck

  describe "violations/1 and max_weekly_avg/1" do
    test "empty schedule has no windows" do
      assert DutyHoursCheck.violations(%{}) == []
      assert DutyHoursCheck.max_weekly_avg(%{}) == 0.0
    end

    test "26 twelve-hour days do not violate, 27 do" do
      ok = Map.new(Date.range(~D[2026-07-06], ~D[2026-07-31]), &{&1, 12})
      assert DutyHoursCheck.violations(ok) == []
      assert DutyHoursCheck.max_weekly_avg(ok) == 78.0

      bad = Map.put(ok, ~D[2026-08-01], 12)

      assert [%{weekly_avg: 81.0, window_start: ~D[2026-07-06], window_end: ~D[2026-08-01]}] =
               DutyHoursCheck.violations(bad)
    end

    test "separate violating stretches stay separate" do
      first = Map.new(Date.range(~D[2026-07-06], ~D[2026-08-02]), &{&1, 12})
      second = Map.new(Date.range(~D[2026-10-05], ~D[2026-11-01]), &{&1, 12})

      assert [%{window_start: ~D[2026-07-06]}, %{window_start: ~D[2026-10-05]}] =
               DutyHoursCheck.violations(Map.merge(first, second))
    end
  end

  describe "daily_hours/1" do
    test "coverage segments count and covered segments do not" do
      segments = [
        %{
          rotation_type: "night_float",
          start_date: ~D[2026-07-06],
          end_date: ~D[2026-07-06],
          covered_by: nil
        },
        %{
          rotation_type: "oncology",
          start_date: ~D[2026-07-07],
          end_date: ~D[2026-07-07],
          covered_by: %{}
        }
      ]

      assert DutyHoursCheck.daily_hours(segments) == %{~D[2026-07-06] => 12}
    end
  end

  describe "compare/2" do
    test "reports new versus pre-existing violations" do
      baseline = Map.new(Date.range(~D[2026-07-06], ~D[2026-08-02]), &{&1, 12})
      hypothetical = Map.put(baseline, ~D[2026-08-03], 12)
      result = DutyHoursCheck.compare(baseline, hypothetical)

      assert result.already_violating
      assert result.violates
      assert length(result.existing_violations) == 1
      assert length(result.new_violations) == 1
      assert result.baseline_max_weekly_avg == 84.0
      assert result.max_weekly_avg == 84.0
    end
  end

  describe "check/4" do
    setup do
      seed_mini_schedule()
    end

    test "a short cover on a light schedule does not violate", %{clare: clare} do
      result = DutyHoursCheck.check(clare.id, "strong_obstetrics", ~D[2026-07-15], ~D[2026-07-16])
      refute result.violates
      refute result.already_violating
      assert result.estimated
      assert result.max_weekly_avg > result.baseline_max_weekly_avg
    end

    test "an existing override changes the baseline", %{clare: clare, tiff: tiff} do
      tiff_ob = rotation_on(tiff, ~D[2026-07-15])

      {:ok, _} =
        ShiftOverrides.create_override(%{
          rotation_id: tiff_ob.id,
          covering_schedule_resident_id: clare.id,
          override_start_date: ~D[2026-07-13],
          override_end_date: ~D[2026-07-19]
        })

      baseline =
        Rotations.effective_segments_for_resident(clare.id) |> DutyHoursCheck.daily_hours()

      assert baseline[~D[2026-07-13]] == 12
    end

    test "a heavy schedule flags a violation" do
      {:ok, schedule} = ResidencySchedule.Schedules.upsert_schedule(2025, "2025–2026")

      {:ok, workhorse} =
        ResidencySchedule.Residents.insert_resident(schedule.id, %{
          position_code: "R1-9",
          residency_year: 1,
          schedule_number: 9,
          name: "Workhorse"
        })

      {:ok, _} =
        Rotations.insert_rotations(workhorse.id, [
          %{
            slot_index: 0,
            start_date: ~D[2025-07-07],
            end_date: ~D[2025-08-01],
            rotation_type: :night_float
          }
        ])

      {:ok, victim} =
        ResidencySchedule.Residents.insert_resident(schedule.id, %{
          position_code: "R1-8",
          residency_year: 1,
          schedule_number: 8,
          name: "Victim"
        })

      {:ok, _} =
        Rotations.insert_rotations(victim.id, [
          %{
            slot_index: 0,
            start_date: ~D[2025-08-03],
            end_date: ~D[2025-08-09],
            rotation_type: :strong_obstetrics
          }
        ])

      result =
        DutyHoursCheck.check(workhorse.id, "strong_obstetrics", ~D[2025-08-03], ~D[2025-08-03])

      assert result.violates
      refute result.already_violating
    end
  end
end
