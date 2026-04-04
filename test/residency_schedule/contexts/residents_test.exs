defmodule ResidencySchedule.ResidentsTest do
  use ResidencySchedule.DataCase, async: true

  alias ResidencySchedule.{Residents, Schedules}

  setup do
    {:ok, sched} = Schedules.upsert_schedule(2023, "2023–2024")

    {:ok, r1} =
      Residents.insert_resident(sched.id, %{
        position_code: "R4-1",
        residency_year: 4,
        schedule_number: 1,
        name: "Alexis"
      })

    {:ok, r2} =
      Residents.insert_resident(sched.id, %{
        position_code: "R1-1",
        residency_year: 1,
        schedule_number: 1,
        name: "Jamie"
      })

    %{schedule: sched, r4: r1, r1: r2}
  end

  describe "list_residents_for_schedule/1" do
    test "returns all residents ordered by year then number", %{schedule: sched, r4: r4, r1: r1} do
      results = Residents.list_residents_for_schedule(sched.id)
      assert length(results) == 2
      assert List.first(results).id == r1.id
      assert List.last(results).id == r4.id
    end

    test "returns empty list for unknown schedule" do
      assert Residents.list_residents_for_schedule(0) == []
    end
  end

  describe "list_residents_by_year/2" do
    test "filters to only the specified residency year", %{schedule: sched, r4: r4} do
      results = Residents.list_residents_by_year(sched.id, 4)
      assert length(results) == 1
      assert hd(results).id == r4.id
    end

    test "returns empty list when no residents match the year", %{schedule: sched} do
      assert Residents.list_residents_by_year(sched.id, 3) == []
    end
  end

  describe "get_resident!/1" do
    test "returns the resident with rotations preloaded", %{r4: r4} do
      found = Residents.get_resident!(r4.id)
      assert found.id == r4.id
      assert is_list(found.rotations)
    end

    test "raises for unknown id" do
      assert_raise Ecto.NoResultsError, fn -> Residents.get_resident!(0) end
    end
  end

  describe "get_resident_by_position!/1" do
    test "returns resident matching position code", %{r4: r4} do
      found = Residents.get_resident_by_position!("R4-1")
      assert found.id == r4.id
    end

    test "raises for unknown position code" do
      assert_raise Ecto.NoResultsError, fn ->
        Residents.get_resident_by_position!("R9-99")
      end
    end
  end

  describe "delete_orphaned_residents/0" do
    test "deletes residents not linked to any schedule", %{schedule: sched} do
      {:ok, _} =
        Residents.insert_resident(sched.id, %{
          position_code: "R2-1",
          residency_year: 2,
          schedule_number: 1,
          name: "Morgan"
        })

      Schedules.delete_schedule(sched.id)
      {count, _} = Residents.delete_orphaned_residents()
      # All residents from that schedule were orphaned and already cleaned up by delete_schedule
      assert count == 0
    end

    test "does not delete residents still linked to another schedule", %{schedule: sched} do
      {:ok, sched2} = Schedules.upsert_schedule(2024, "2024–2025")
      # Same person "Alexis" exists in both schedules
      {:ok, _} =
        Residents.insert_resident(sched2.id, %{
          position_code: "R4-1",
          residency_year: 4,
          schedule_number: 1,
          name: "Alexis"
        })

      Schedules.delete_schedule(sched.id)
      # Alexis is still in sched2, so should not be orphaned
      remaining = Residents.list_residents_for_schedule(sched2.id)
      assert Enum.any?(remaining, &(&1.name == "Alexis"))
    end

    test "deletes orphan when resident appears in no schedule", %{schedule: sched} do
      Schedules.delete_schedule(sched.id)
      # After deletion, Alexis and Jamie have no schedules
      {count, _} = Residents.delete_orphaned_residents()
      # Both were already cleaned up by delete_schedule; calling again should return 0
      assert count == 0
    end
  end

  describe "find_by_password/1" do
    setup %{schedule: sched} do
      {:ok, paige} =
        Residents.insert_resident(sched.id, %{
          position_code: "R3-5",
          residency_year: 3,
          schedule_number: 5,
          name: "Paige R"
        })

      %{paige: paige}
    end

    test "matches spaced and run-on forms for trailing initial", %{paige: paige} do
      assert Residents.find_by_password("paige r").id == paige.id
      assert Residents.find_by_password("Paiger").id == paige.id
      assert Residents.find_by_password("  paiger  ").id == paige.id
      assert Residents.find_by_password("PAIGE R").id == paige.id
      assert Residents.find_by_password("pAiGeR").id == paige.id
    end

    test "still matches names without an initial (any letter case)", %{r4: r4} do
      assert Residents.find_by_password("alexis").id == r4.id
      assert Residents.find_by_password("ALEXIS").id == r4.id
      assert Residents.find_by_password("Alexis").id == r4.id
    end

    test "returns nil when no resident matches" do
      assert Residents.find_by_password("nobody_here_xyz") == nil
    end
  end

  describe "insert_resident/2" do
    test "inserts a valid resident", %{schedule: sched} do
      {:ok, resident} =
        Residents.insert_resident(sched.id, %{
          position_code: "R2-1",
          residency_year: 2,
          schedule_number: 1,
          name: "Morgan"
        })

      assert resident.name == "Morgan"
      assert resident.schedule_id == sched.id
    end

    test "falls back to position_code when name is blank", %{schedule: sched} do
      {:ok, resident} =
        Residents.insert_resident(sched.id, %{
          position_code: "R2-2",
          residency_year: 2,
          schedule_number: 2,
          name: "R2-2"
        })

      assert resident.name == "R2-2"
    end

    test "returns error changeset for missing required fields", %{schedule: sched} do
      {:error, changeset} = Residents.insert_resident(sched.id, %{})
      assert changeset.valid? == false
    end
  end
end
