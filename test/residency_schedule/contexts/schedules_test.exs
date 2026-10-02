defmodule ResidencySchedule.SchedulesTest do
  use ResidencySchedule.DataCase, async: true

  alias ResidencySchedule.{Residents, Schedules}

  describe "academic_year_label/1" do
    test "formats a start year into an en-dash range label" do
      assert Schedules.academic_year_label(2026) == "2026–2027"
    end

    test "works for any integer year" do
      assert Schedules.academic_year_label(2023) == "2023–2024"
    end
  end

  describe "list_schedules/0" do
    test "returns empty list when no schedules exist" do
      assert Schedules.list_schedules() == []
    end

    test "returns schedules ordered oldest first" do
      {:ok, _} = Schedules.upsert_schedule(2026, "2026–2027")
      {:ok, _} = Schedules.upsert_schedule(2023, "2023–2024")
      [first | _] = Schedules.list_schedules()
      assert first.academic_year == 2023
    end
  end

  describe "upsert_schedule/2" do
    test "creates a new schedule" do
      {:ok, sched} = Schedules.upsert_schedule(2026, "2026–2027")
      assert sched.academic_year == 2026
      assert sched.label == "2026–2027"
    end

    test "updates label when academic_year already exists" do
      {:ok, _} = Schedules.upsert_schedule(2026, "old label")
      {:ok, updated} = Schedules.upsert_schedule(2026, "2026–2027")
      assert updated.label == "2026–2027"
      assert length(Schedules.list_schedules()) == 1
    end
  end

  describe "get_schedule!/1" do
    test "returns schedule by id" do
      {:ok, sched} = Schedules.upsert_schedule(2026, "2026–2027")
      found = Schedules.get_schedule!(sched.id)
      assert found.academic_year == 2026
    end

    test "raises for unknown id" do
      assert_raise Ecto.NoResultsError, fn -> Schedules.get_schedule!(0) end
    end
  end

  describe "get_by_year!/1" do
    test "returns schedule matching academic year" do
      {:ok, _} = Schedules.upsert_schedule(2026, "2026–2027")
      found = Schedules.get_by_year!(2026)
      assert found.academic_year == 2026
    end

    test "raises for unknown year" do
      assert_raise Ecto.NoResultsError, fn -> Schedules.get_by_year!(9999) end
    end
  end

  describe "delete_schedule/1" do
    test "returns error when schedule does not exist" do
      assert {:error, :not_found} = Schedules.delete_schedule(0)
    end

    test "deletes the schedule and orphaned residents" do
      {:ok, sched} = Schedules.upsert_schedule(2026, "2026–2027")

      {:ok, _} =
        Residents.insert_resident(sched.id, %{
          position_code: "R1-1",
          residency_year: 1,
          schedule_number: 1,
          name: "OnlyHere"
        })

      {:ok, _} = Schedules.delete_schedule(sched.id)
      assert Schedules.get_by_year(2026) == nil
      assert Residents.list_residents() |> Enum.any?(&(&1.name == "OnlyHere")) == false
    end

    test "does not delete residents shared with another schedule" do
      {:ok, sched1} = Schedules.upsert_schedule(2026, "2026–2027")
      {:ok, sched2} = Schedules.upsert_schedule(2027, "2027–2028")

      {:ok, _} =
        Residents.insert_resident(sched1.id, %{
          position_code: "R1-1",
          residency_year: 1,
          schedule_number: 1,
          name: "Shared"
        })

      {:ok, _} =
        Residents.insert_resident(sched2.id, %{
          position_code: "R1-1",
          residency_year: 1,
          schedule_number: 1,
          name: "Shared"
        })

      {:ok, _} = Schedules.delete_schedule(sched1.id)
      assert Residents.list_residents() |> Enum.any?(&(&1.name == "Shared"))
    end
  end

  describe "list_schedule_ranges/0" do
    test "reports the first and last rotation dates per schedule, oldest first" do
      fixtures = ResidencySchedule.ScheduleFixtures.seed_mini_schedule()
      ResidencySchedule.ScheduleFixtures.seed_prior_year_for_clare(fixtures)

      assert [
               %{
                 academic_year: 2025,
                 label: "2025–2026",
                 start_date: ~D[2025-07-07],
                 end_date: ~D[2025-07-27]
               },
               %{
                 academic_year: 2026,
                 label: "2026–2027",
                 start_date: ~D[2026-07-06],
                 end_date: ~D[2026-07-26]
               }
             ] = Schedules.list_schedule_ranges()
    end

    test "a schedule without rotations has nil dates" do
      {:ok, schedule} = Schedules.upsert_schedule(2030, "2030–2031")
      assert [%{id: id, start_date: nil, end_date: nil}] = Schedules.list_schedule_ranges()
      assert id == schedule.id
    end

    test "is empty with no schedules" do
      assert Schedules.list_schedule_ranges() == []
    end
  end

  describe "latest_schedule/0" do
    test "returns nil when no schedules" do
      assert Schedules.latest_schedule() == nil
    end

    test "returns the schedule with the highest academic_year" do
      {:ok, _} = Schedules.upsert_schedule(2023, "2023–2024")
      {:ok, _} = Schedules.upsert_schedule(2026, "2026–2027")
      latest = Schedules.latest_schedule()
      assert latest.academic_year == 2026
    end
  end
end
