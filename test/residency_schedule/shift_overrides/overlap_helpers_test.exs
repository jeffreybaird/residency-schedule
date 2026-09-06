defmodule ResidencySchedule.ShiftOverrides.OverlapHelpersTest do
  use ResidencySchedule.DataCase, async: true

  import ResidencySchedule.ScheduleFixtures

  alias ResidencySchedule.{Rotations, ShiftOverrides}

  setup do
    fixtures = seed_mini_schedule()
    tiff_ob = rotation_on(fixtures.tiff, ~D[2026-07-15])

    {:ok, _} =
      ShiftOverrides.create_override(%{
        rotation_id: tiff_ob.id,
        covering_schedule_resident_id: fixtures.clare.id,
        override_start_date: ~D[2026-07-15],
        override_end_date: ~D[2026-07-16]
      })

    Map.put(fixtures, :tiff_ob, tiff_ob)
  end

  describe "rotation_covered_in_range?/3" do
    test "true when ranges overlap", ctx do
      assert ShiftOverrides.rotation_covered_in_range?(
               ctx.tiff_ob.id,
               ~D[2026-07-16],
               ~D[2026-07-19]
             )
    end

    test "false when ranges do not overlap", ctx do
      refute ShiftOverrides.rotation_covered_in_range?(
               ctx.tiff_ob.id,
               ~D[2026-07-17],
               ~D[2026-07-19]
             )
    end
  end

  describe "resident_covering_in_range?/3" do
    test "true for the covering resident on an overlapping day", ctx do
      assert ShiftOverrides.resident_covering_in_range?(
               ctx.clare.id,
               ~D[2026-07-14],
               ~D[2026-07-15]
             )
    end

    test "false for a resident who is not covering", ctx do
      refute ShiftOverrides.resident_covering_in_range?(
               ctx.mary.id,
               ~D[2026-07-14],
               ~D[2026-07-16]
             )
    end
  end

  describe "Rotations.get_rotation_for_resident_on_date/2 and get_rotation/1" do
    test "finds the rotation containing the date with the resident name", ctx do
      rotation = Rotations.get_rotation_for_resident_on_date(ctx.clare.id, ~D[2026-07-20])
      assert rotation.rotation_type == "night_float"
      assert rotation.schedule_resident.name == "Clare"
    end

    test "nil outside any rotation", ctx do
      assert Rotations.get_rotation_for_resident_on_date(ctx.clare.id, ~D[2026-08-20]) == nil
    end

    test "get_rotation by id and unknown id", ctx do
      assert Rotations.get_rotation(ctx.tiff_ob.id).schedule_resident.name == "Tiff"
      assert Rotations.get_rotation(0) == nil
    end
  end
end
