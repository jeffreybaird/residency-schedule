defmodule ResidencySchedule.IcalOverridesTest do
  use ResidencySchedule.DataCase, async: true

  alias ResidencySchedule.{Ical, Residents, Rotations, Schedules, ShiftOverrides}

  setup do
    {:ok, sched} = Schedules.upsert_schedule(2023, "2023–2024")

    {:ok, isolde} =
      Residents.insert_resident(sched.id, %{
        position_code: "R4-1",
        residency_year: 4,
        schedule_number: 1,
        name: "Isolde"
      })

    {:ok, nora} =
      Residents.insert_resident(sched.id, %{
        position_code: "R2-1",
        residency_year: 2,
        schedule_number: 1,
        name: "Nora"
      })

    # Isolde: Night Float Jul 1–14
    {:ok, _} =
      Rotations.insert_rotations(isolde.id, [
        %{
          slot_index: 0,
          start_date: ~D[2023-07-01],
          end_date: ~D[2023-07-14],
          rotation_type: :night_float
        }
      ])

    # Nora: Elective Jul 1–14
    {:ok, _} =
      Rotations.insert_rotations(nora.id, [
        %{
          slot_index: 0,
          start_date: ~D[2023-07-01],
          end_date: ~D[2023-07-14],
          rotation_type: :elective
        }
      ])

    clares_rotation = Rotations.list_rotations_for_resident(isolde.id) |> hd()

    %{sched: sched, isolde: isolde, nora: nora, rotation: clares_rotation}
  end

  describe "build_for_person/1" do
    test "includes events from every academic year of the person", %{isolde: isolde} do
      {:ok, later} = Schedules.upsert_schedule(2024, "2024–2025")

      {:ok, later_sr} =
        Residents.insert_resident(later.id, %{
          position_code: "R4-2",
          residency_year: 4,
          schedule_number: 2,
          name: "Isolde"
        })

      {:ok, _} =
        Rotations.insert_rotations(later_sr.id, [
          %{
            slot_index: 0,
            start_date: ~D[2024-07-01],
            end_date: ~D[2024-07-14],
            rotation_type: :vacation
          }
        ])

      person =
        ResidencySchedule.Repo.get!(ResidencySchedule.Residents.Resident, isolde.resident_id)

      result = Ical.build_for_person(person)

      assert result =~ "X-WR-CALNAME:Isolde"
      assert result =~ "20230701"
      assert result =~ "20240701"
    end

    test "excludes periods covered by someone else", %{
      isolde: isolde,
      nora: nora,
      rotation: rot
    } do
      {:ok, _} =
        ShiftOverrides.create_override(%{
          rotation_id: rot.id,
          covering_schedule_resident_id: nora.id,
          override_start_date: ~D[2023-07-08],
          override_end_date: ~D[2023-07-14]
        })

      person =
        ResidencySchedule.Repo.get!(ResidencySchedule.Residents.Resident, isolde.resident_id)

      result = Ical.build_for_person(person)

      assert result =~ "20230701"
      refute result =~ "20230710"
    end
  end

  describe "build/1" do
    test "covered period is excluded from original resident's iCal", %{
      isolde: isolde,
      nora: nora,
      rotation: rot
    } do
      {:ok, _} =
        ShiftOverrides.create_override(%{
          rotation_id: rot.id,
          covering_schedule_resident_id: nora.id,
          override_start_date: ~D[2023-07-08],
          override_end_date: ~D[2023-07-14]
        })

      result = Ical.build(isolde)

      # Jul 1–7 (free): Isolde is working, these nights should appear
      assert result =~ "20230630T180000"
      # Jul 8–14 (covered by Nora): should NOT appear for Isolde
      refute result =~ "20230707T180000"
    end

    test "covering resident's own shift is removed for covered dates", %{
      isolde: _clare,
      nora: nora,
      rotation: rot
    } do
      {:ok, _} =
        ShiftOverrides.create_override(%{
          rotation_id: rot.id,
          covering_schedule_resident_id: nora.id,
          override_start_date: ~D[2023-07-08],
          override_end_date: ~D[2023-07-14]
        })

      result = Ical.build(nora)

      # Nora's Elective Jul 1–7 should appear (she's working)
      assert result =~ "DTSTART:20230701T060000"
      # Nora's Elective Jul 8–14 should NOT appear (she's covering Isolde, not on Elective)
      refute result =~ "DTSTART:20230808T060000"
      # Nora's Night Float coverage Jul 8–14 SHOULD appear
      assert result =~ "20230707T180000"
    end

    test "produces valid VCALENDAR with no overrides", %{isolde: isolde} do
      result = Ical.build(isolde)
      assert result =~ "BEGIN:VCALENDAR"
      assert result =~ "END:VCALENDAR"
    end
  end
end
