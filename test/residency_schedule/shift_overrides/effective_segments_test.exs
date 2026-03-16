defmodule ResidencySchedule.EffectiveSegmentsTest do
  use ResidencySchedule.DataCase, async: true

  alias ResidencySchedule.{Schedules, Residents, Rotations, ShiftOverrides}

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

  describe "effective_segments_for_resident/1 with no overrides" do
    test "returns the raw rotation as a single segment", %{clare: clare} do
      segs = Rotations.effective_segments_for_resident(clare.id)
      assert length(segs) == 1
      seg = hd(segs)
      assert seg.rotation_type == "night_float"
      assert seg.start_date == ~D[2023-07-01]
      assert seg.end_date == ~D[2023-07-14]
      assert seg.is_coverage == false
      assert seg.covered_by == nil
    end

    test "returns empty list for resident with no rotations", %{sched: sched} do
      {:ok, newbie} =
        Residents.insert_resident(sched.id, %{
          position_code: "R1-1",
          residency_year: 1,
          schedule_number: 1,
          name: "Newbie"
        })

      assert Rotations.effective_segments_for_resident(newbie.id) == []
    end
  end

  describe "effective_segments_for_resident/1 for the original resident" do
    test "splits rotation: pre-override segment is free, override segment has covered_by set", %{
      clare: clare,
      emily: emily,
      rotation: rot
    } do
      {:ok, _} =
        ShiftOverrides.create_override(%{
          rotation_id: rot.id,
          covering_resident_id: emily.id,
          override_start_date: ~D[2023-07-08],
          override_end_date: ~D[2023-07-14]
        })

      segs = Rotations.effective_segments_for_resident(clare.id)

      free = Enum.filter(segs, &(&1.covered_by == nil and not &1.is_coverage))
      covered = Enum.filter(segs, &(&1.covered_by != nil))

      assert length(free) == 1
      assert hd(free).start_date == ~D[2023-07-01]
      assert hd(free).end_date == ~D[2023-07-07]

      assert length(covered) == 1
      assert hd(covered).start_date == ~D[2023-07-08]
      assert hd(covered).end_date == ~D[2023-07-14]
      assert hd(covered).covered_by.name == "Emily"
    end

    test "override covering entire rotation yields only a covered segment", %{
      clare: clare,
      emily: emily,
      rotation: rot
    } do
      {:ok, _} =
        ShiftOverrides.create_override(%{
          rotation_id: rot.id,
          covering_resident_id: emily.id,
          override_start_date: ~D[2023-07-01],
          override_end_date: ~D[2023-07-14]
        })

      segs = Rotations.effective_segments_for_resident(clare.id)
      free = Enum.filter(segs, &(&1.covered_by == nil and not &1.is_coverage))
      covered = Enum.filter(segs, &(&1.covered_by != nil))

      assert free == []
      assert length(covered) == 1
    end
  end

  describe "effective_segments_for_resident/1 for the covering resident" do
    test "covering resident gets a coverage segment added", %{emily: emily, rotation: rot} do
      {:ok, _} =
        ShiftOverrides.create_override(%{
          rotation_id: rot.id,
          covering_resident_id: emily.id,
          override_start_date: ~D[2023-07-08],
          override_end_date: ~D[2023-07-14]
        })

      segs = Rotations.effective_segments_for_resident(emily.id)
      coverage = Enum.filter(segs, & &1.is_coverage)
      assert length(coverage) == 1
      seg = hd(coverage)
      assert seg.rotation_type == "night_float"
      assert seg.start_date == ~D[2023-07-08]
      assert seg.end_date == ~D[2023-07-14]
      assert seg.original_resident.name == "Clare"
    end

    test "covering period is removed from covering resident's own rotation", %{
      emily: emily,
      rotation: rot
    } do
      {:ok, _} =
        ShiftOverrides.create_override(%{
          rotation_id: rot.id,
          covering_resident_id: emily.id,
          override_start_date: ~D[2023-07-08],
          override_end_date: ~D[2023-07-14]
        })

      segs = Rotations.effective_segments_for_resident(emily.id)
      # Emily's own Elective should only cover Jul 1–7 (Jul 8–14 removed)
      own = Enum.filter(segs, fn s -> s.rotation_type == "elective" and not s.is_coverage end)
      assert length(own) == 1
      assert hd(own).start_date == ~D[2023-07-01]
      assert hd(own).end_date == ~D[2023-07-07]
    end
  end

  describe "list_effective_co_service_days/2" do
    test "returns shared days when two residents are on the same service", %{sched: sched} do
      {:ok, rc} =
        Residents.insert_resident(sched.id, %{
          position_code: "R3-1",
          residency_year: 3,
          schedule_number: 1,
          name: "Sam"
        })

      {:ok, rd} =
        Residents.insert_resident(sched.id, %{
          position_code: "R3-2",
          residency_year: 3,
          schedule_number: 2,
          name: "Alex"
        })

      Rotations.insert_rotations(rc.id, [
        %{slot_index: 5, start_date: ~D[2023-08-01], end_date: ~D[2023-08-07], rotation_type: :oncology}
      ])

      Rotations.insert_rotations(rd.id, [
        %{slot_index: 5, start_date: ~D[2023-08-01], end_date: ~D[2023-08-07], rotation_type: :oncology}
      ])

      days = Rotations.list_effective_co_service_days(rc.id, rd.id)
      assert length(days) == 7
      assert hd(days).rotation_type == "oncology"
    end

    test "covered period is excluded from effective co-service", %{
      clare: clare,
      emily: emily,
      rotation: rot,
      sched: _sched
    } do
      # Give Emily a Night Float rotation too (same as Clare) for full overlap
      {:ok, _} =
        Rotations.insert_rotations(emily.id, [
          %{slot_index: 5, start_date: ~D[2023-07-01], end_date: ~D[2023-07-14], rotation_type: :night_float}
        ])

      # Override: Emily covers Clare Jul 8–14
      {:ok, _} =
        ShiftOverrides.create_override(%{
          rotation_id: rot.id,
          covering_resident_id: emily.id,
          override_start_date: ~D[2023-07-08],
          override_end_date: ~D[2023-07-14]
        })

      # Clare's covered segment (Jul 8–14) should not count as a shared day
      # Clare's free: Jul 1–7, Emily covering for Clare: Jul 8–14 (same type)
      # But Clare's covered_by segment is excluded from co-service
      days = Rotations.list_effective_co_service_days(clare.id, emily.id)
      dates = Enum.map(days, & &1.date)
      # Jul 8–14 should NOT appear since Clare is covered (not working those days)
      refute ~D[2023-07-10] in dates
    end
  end
end
