defmodule ResidencySchedule.IcalOverridesTest do
  use ResidencySchedule.DataCase, async: true

  alias ResidencySchedule.{Schedules, Residents, Rotations, ShiftOverrides, Ical}

  setup do
    {:ok, sched} = Schedules.upsert_schedule(2023, "2023–2024")

    {:ok, clare} =
      Residents.insert_resident(sched.id, %{
        position_code: "R4-1",
        residency_year: 4,
        schedule_number: 1,
        name: "Clare"
      })

    {:ok, emily} =
      Residents.insert_resident(sched.id, %{
        position_code: "R2-1",
        residency_year: 2,
        schedule_number: 1,
        name: "Emily"
      })

    # Clare: Night Float Jul 1–14
    {:ok, _} =
      Rotations.insert_rotations(clare.id, [
        %{slot_index: 0, start_date: ~D[2023-07-01], end_date: ~D[2023-07-14], rotation_type: :night_float}
      ])

    # Emily: Elective Jul 1–14
    {:ok, _} =
      Rotations.insert_rotations(emily.id, [
        %{slot_index: 0, start_date: ~D[2023-07-01], end_date: ~D[2023-07-14], rotation_type: :elective}
      ])

    clares_rotation = Rotations.list_rotations_for_resident(clare.id) |> hd()

    %{sched: sched, clare: clare, emily: emily, rotation: clares_rotation}
  end

  describe "build/1" do
    test "covered period is excluded from original resident's iCal", %{clare: clare, emily: emily, rotation: rot} do
      {:ok, _} =
        ShiftOverrides.create_override(%{
          rotation_id: rot.id,
          covering_schedule_resident_id: emily.id,
          override_start_date: ~D[2023-07-08],
          override_end_date: ~D[2023-07-14]
        })

      result = Ical.build(clare)

      # Jul 1–7 (free): Clare is working, these nights should appear
      assert result =~ "20230630T180000"
      # Jul 8–14 (covered by Emily): should NOT appear for Clare
      refute result =~ "20230707T180000"
    end

    test "covering resident's own shift is removed for covered dates", %{clare: _clare, emily: emily, rotation: rot} do
      {:ok, _} =
        ShiftOverrides.create_override(%{
          rotation_id: rot.id,
          covering_schedule_resident_id: emily.id,
          override_start_date: ~D[2023-07-08],
          override_end_date: ~D[2023-07-14]
        })

      result = Ical.build(emily)

      # Emily's Elective Jul 1–7 should appear (she's working)
      assert result =~ "DTSTART:20230701T060000"
      # Emily's Elective Jul 8–14 should NOT appear (she's covering Clare, not on Elective)
      refute result =~ "DTSTART:20230808T060000"
      # Emily's Night Float coverage Jul 8–14 SHOULD appear
      assert result =~ "20230707T180000"
    end

    test "produces valid VCALENDAR with no overrides", %{clare: clare} do
      result = Ical.build(clare)
      assert result =~ "BEGIN:VCALENDAR"
      assert result =~ "END:VCALENDAR"
    end
  end
end
