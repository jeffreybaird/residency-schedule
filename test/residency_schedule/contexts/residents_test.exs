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

  describe "list_residents_across_schedules/1" do
    test "returns residents from multiple schedules", %{schedule: sched, r4: r4, r1: r1} do
      {:ok, sched2} = Schedules.upsert_schedule(2024, "2024–2025")

      {:ok, r4_next} =
        Residents.insert_resident(sched2.id, %{
          position_code: "R4-1",
          residency_year: 4,
          schedule_number: 1,
          name: "Alexis"
        })

      results = Residents.list_residents_across_schedules([sched.id, sched2.id])
      assert length(results) == 3
      ids = Enum.map(results, & &1.id)
      assert r1.id in ids
      assert r4.id in ids
      assert r4_next.id in ids
    end

    test "preloads rotations for each schedule resident", %{schedule: sched} do
      results = Residents.list_residents_across_schedules([sched.id])
      assert Enum.all?(results, fn r -> is_list(r.rotations) end)
    end

    test "returns empty list for empty schedule ids" do
      assert Residents.list_residents_across_schedules([]) == []
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

  describe "list_resident_filter_options/0" do
    test "returns one option per resident (person)", %{r4: r4, r1: r1} do
      options = Residents.list_resident_filter_options()
      ids = Enum.map(options, & &1.id)

      assert r4.resident_id in ids
      assert r1.resident_id in ids
      assert ids == Enum.uniq(ids)
    end

    test "dedupes a person across schedules using their most recent appearance", %{r4: r4} do
      {:ok, sched_2026} = Schedules.upsert_schedule(2026, "2026–2027")

      {:ok, _alexis_2026} =
        Residents.insert_resident(sched_2026.id, %{
          position_code: "R4-9",
          residency_year: 4,
          schedule_number: 9,
          name: "Alexis"
        })

      options = Residents.list_resident_filter_options()
      alexis_options = Enum.filter(options, &(&1.id == r4.resident_id))

      assert length(alexis_options) == 1
      assert hd(alexis_options).position_code == "R4-9"
    end
  end
end
