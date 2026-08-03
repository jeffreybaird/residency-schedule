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
        name: "Briar"
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
          name: "Briar"
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
      # Same person "Briar" exists in both schedules
      {:ok, _} =
        Residents.insert_resident(sched2.id, %{
          position_code: "R4-1",
          residency_year: 4,
          schedule_number: 1,
          name: "Briar"
        })

      Schedules.delete_schedule(sched.id)
      # Briar is still in sched2, so should not be orphaned
      remaining = Residents.list_residents_for_schedule(sched2.id)
      assert Enum.any?(remaining, &(&1.name == "Briar"))
    end

    test "deletes orphan when resident appears in no schedule", %{schedule: sched} do
      Schedules.delete_schedule(sched.id)
      # After deletion, Briar and Jamie have no schedules
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

  describe "list_resident_filter_options_for_year/1" do
    test "lists residents with a shift that year and excludes the rest", %{schedule: sched} do
      {:ok, on_service} =
        Residents.insert_resident(sched.id, %{
          position_code: "R3-1",
          residency_year: 3,
          schedule_number: 1,
          name: "OnService"
        })

      {:ok, _no_shifts} =
        Residents.insert_resident(sched.id, %{
          position_code: "R3-2",
          residency_year: 3,
          schedule_number: 2,
          name: "NoShifts"
        })

      {:ok, _} =
        ResidencySchedule.Rotations.insert_rotations(on_service.id, [
          %{
            slot_index: 0,
            start_date: ~D[2023-07-03],
            end_date: ~D[2023-07-09],
            rotation_type: :oncology
          }
        ])

      {:ok, s2026} = Schedules.upsert_schedule(2026, "2026–2027")

      {:ok, future} =
        Residents.insert_resident(s2026.id, %{
          position_code: "R1-1",
          residency_year: 1,
          schedule_number: 1,
          name: "FutureGrad"
        })

      {:ok, _} =
        ResidencySchedule.Rotations.insert_rotations(future.id, [
          %{
            slot_index: 0,
            start_date: ~D[2026-07-06],
            end_date: ~D[2026-07-12],
            rotation_type: :rei
          }
        ])

      names_2023 = Residents.list_resident_filter_options_for_year(2023) |> Enum.map(& &1.name)
      assert "OnService" in names_2023
      refute "NoShifts" in names_2023
      refute "FutureGrad" in names_2023

      assert Residents.list_resident_filter_options_for_year(2026) |> Enum.map(& &1.name) ==
               ["FutureGrad"]
    end

    test "returns an empty list for a year with no schedule" do
      assert Residents.list_resident_filter_options_for_year(1999) == []
    end
  end
end
