defmodule ResidencySchedule.ShiftOverridesTest do
  use ResidencySchedule.DataCase, async: true

  alias ResidencySchedule.{Schedules, Residents, Rotations, ShiftOverrides}

  setup do
    {:ok, sched} = Schedules.upsert_schedule(2023, "2023–2024")

    {:ok, ra} =
      Residents.insert_resident(sched.id, %{
        position_code: "R4-1",
        residency_year: 4,
        schedule_number: 1,
        name: "Clare"
      })

    {:ok, rb} =
      Residents.insert_resident(sched.id, %{
        position_code: "R2-1",
        residency_year: 2,
        schedule_number: 1,
        name: "Emily"
      })

    # Clare is on Night Float Jul 1–14
    {:ok, _} =
      Rotations.insert_rotations(ra.id, [
        %{
          slot_index: 0,
          start_date: ~D[2023-07-01],
          end_date: ~D[2023-07-14],
          rotation_type: :night_float
        }
      ])

    # Emily is on Elective Jul 1–14
    {:ok, _} =
      Rotations.insert_rotations(rb.id, [
        %{
          slot_index: 0,
          start_date: ~D[2023-07-01],
          end_date: ~D[2023-07-14],
          rotation_type: :elective
        }
      ])

    rotation_a = Rotations.list_rotations_for_resident(ra.id) |> hd()

    %{sched: sched, ra: ra, rb: rb, rotation_a: rotation_a}
  end

  describe "create_override/1" do
    test "creates a valid override", %{rotation_a: rot, rb: rb} do
      attrs = %{
        rotation_id: rot.id,
        covering_schedule_resident_id: rb.id,
        override_start_date: ~D[2023-07-08],
        override_end_date: ~D[2023-07-14]
      }

      assert {:ok, override} = ShiftOverrides.create_override(attrs)
      assert override.override_start_date == ~D[2023-07-08]
      assert override.override_end_date == ~D[2023-07-14]
    end

    test "returns error when end date is before start date", %{rotation_a: rot, rb: rb} do
      attrs = %{
        rotation_id: rot.id,
        covering_schedule_resident_id: rb.id,
        override_start_date: ~D[2023-07-14],
        override_end_date: ~D[2023-07-08]
      }

      assert {:error, changeset} = ShiftOverrides.create_override(attrs)
      assert changeset.errors[:override_end_date]
    end

    test "returns error when required fields missing" do
      assert {:error, changeset} = ShiftOverrides.create_override(%{})
      assert changeset.errors[:rotation_id]
      assert changeset.errors[:covering_schedule_resident_id]
    end
  end

  describe "list_overrides_for_resident_as_original/1" do
    test "returns overrides where resident's rotation is being covered", %{
      rotation_a: rot,
      ra: ra,
      rb: rb
    } do
      {:ok, _} =
        ShiftOverrides.create_override(%{
          rotation_id: rot.id,
          covering_schedule_resident_id: rb.id,
          override_start_date: ~D[2023-07-08],
          override_end_date: ~D[2023-07-14]
        })

      overrides = ShiftOverrides.list_overrides_for_resident_as_original(ra.id)
      assert length(overrides) == 1
      assert hd(overrides).covering_schedule_resident.name == "Emily"
    end

    test "returns empty for resident with no overrides", %{rb: rb} do
      assert ShiftOverrides.list_overrides_for_resident_as_original(rb.id) == []
    end
  end

  describe "list_overrides_for_resident_as_cover/1" do
    test "returns overrides where resident is the covering resident", %{
      rotation_a: rot,
      ra: _ra,
      rb: rb
    } do
      {:ok, _} =
        ShiftOverrides.create_override(%{
          rotation_id: rot.id,
          covering_schedule_resident_id: rb.id,
          override_start_date: ~D[2023-07-08],
          override_end_date: ~D[2023-07-14]
        })

      overrides = ShiftOverrides.list_overrides_for_resident_as_cover(rb.id)
      assert length(overrides) == 1
      assert hd(overrides).rotation.schedule_resident.name == "Clare"
    end

    test "returns empty for resident who is not covering anyone", %{ra: ra} do
      assert ShiftOverrides.list_overrides_for_resident_as_cover(ra.id) == []
    end
  end

  describe "list_overrides_for_month/2" do
    test "returns overrides overlapping the given month", %{rotation_a: rot, rb: rb} do
      {:ok, _} =
        ShiftOverrides.create_override(%{
          rotation_id: rot.id,
          covering_schedule_resident_id: rb.id,
          override_start_date: ~D[2023-07-08],
          override_end_date: ~D[2023-07-14]
        })

      overrides = ShiftOverrides.list_overrides_for_month(2023, 7)
      assert length(overrides) == 1
    end

    test "returns empty for a month with no overrides", %{} do
      assert ShiftOverrides.list_overrides_for_month(2022, 1) == []
    end
  end

  describe "list_overrides_in_range/2" do
    test "returns overrides overlapping the range across all schedules", %{
      rotation_a: rot,
      rb: rb
    } do
      {:ok, _} =
        ShiftOverrides.create_override(%{
          rotation_id: rot.id,
          covering_schedule_resident_id: rb.id,
          override_start_date: ~D[2023-07-08],
          override_end_date: ~D[2023-07-14]
        })

      overrides = ShiftOverrides.list_overrides_in_range(~D[2023-07-10], ~D[2023-07-11])
      assert length(overrides) == 1
      assert hd(overrides).rotation_id == rot.id
    end

    test "returns empty when the range does not overlap overrides", %{} do
      assert ShiftOverrides.list_overrides_in_range(~D[2020-01-01], ~D[2020-01-07]) == []
    end
  end

  describe "list_overrides_for_schedule_in_range/3" do
    test "returns overrides for rotations on that schedule overlapping the range", %{
      rotation_a: rot,
      sched: sched,
      rb: rb
    } do
      {:ok, _} =
        ShiftOverrides.create_override(%{
          rotation_id: rot.id,
          covering_schedule_resident_id: rb.id,
          override_start_date: ~D[2023-07-08],
          override_end_date: ~D[2023-07-14]
        })

      overrides =
        ShiftOverrides.list_overrides_for_schedule_in_range(
          sched.id,
          ~D[2023-07-10],
          ~D[2023-07-11]
        )

      assert length(overrides) == 1
      assert hd(overrides).rotation_id == rot.id
      assert hd(overrides).covering_schedule_resident_id == rb.id
    end

    test "returns empty when the range does not overlap overrides", %{sched: sched} do
      assert ShiftOverrides.list_overrides_for_schedule_in_range(
               sched.id,
               ~D[2020-01-01],
               ~D[2020-01-07]
             ) == []
    end
  end

  describe "list_rotations_for_type_in_range/3" do
    test "returns rotations of a given type overlapping the date range", %{ra: ra} do
      rotations =
        ShiftOverrides.list_rotations_for_type_in_range(
          "night_float",
          ~D[2023-07-05],
          ~D[2023-07-10]
        )

      assert Enum.any?(rotations, &(&1.schedule_resident_id == ra.id))
    end

    test "returns empty for a type not present in the range" do
      assert ShiftOverrides.list_rotations_for_type_in_range(
               "oncology",
               ~D[2023-07-01],
               ~D[2023-07-14]
             ) == []
    end
  end

  describe "delete_override/1" do
    test "removes an override", %{rotation_a: rot, rb: rb} do
      {:ok, override} =
        ShiftOverrides.create_override(%{
          rotation_id: rot.id,
          covering_schedule_resident_id: rb.id,
          override_start_date: ~D[2023-07-08],
          override_end_date: ~D[2023-07-14]
        })

      assert {:ok, _} = ShiftOverrides.delete_override(override.id)
      assert ShiftOverrides.list_all_overrides() == []
    end
  end
end
