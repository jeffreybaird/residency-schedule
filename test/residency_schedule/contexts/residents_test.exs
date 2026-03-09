defmodule ResidencySchedule.ResidentsTest do
  use ResidencySchedule.DataCase, async: true

  alias ResidencySchedule.{Residents, Schedules}

  setup do
    {:ok, sched} = Schedules.upsert_schedule(2023, "2023–2024")
    {:ok, r1} = Residents.insert_resident(sched.id, %{position_code: "R4-1", residency_year: 4, schedule_number: 1, name: "Alexis"})
    {:ok, r2} = Residents.insert_resident(sched.id, %{position_code: "R1-1", residency_year: 1, schedule_number: 1, name: "Jamie"})
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

  describe "insert_resident/2" do
    test "inserts a valid resident", %{schedule: sched} do
      {:ok, resident} = Residents.insert_resident(sched.id, %{
        position_code: "R2-1",
        residency_year: 2,
        schedule_number: 1,
        name: "Morgan"
      })
      assert resident.name == "Morgan"
      assert resident.schedule_id == sched.id
    end

    test "falls back to position_code when name is blank", %{schedule: sched} do
      {:ok, resident} = Residents.insert_resident(sched.id, %{
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
