defmodule ResidencySchedule.Residents.CalendarTokenTest do
  use ResidencySchedule.DataCase, async: true

  alias ResidencySchedule.{Schedules, Residents}

  setup do
    {:ok, sched} = Schedules.upsert_schedule(2023, "2023–2024")

    {:ok, resident} =
      Residents.insert_resident(sched.id, %{
        position_code: "R4-1",
        residency_year: 4,
        schedule_number: 1,
        name: "Isolde"
      })

    %{resident: resident}
  end

  describe "insert_resident/2" do
    test "assigns a unique calendar_token on insert", %{resident: resident} do
      assert resident.calendar_token != nil
      assert String.length(resident.calendar_token) > 0
    end

    test "two residents get different tokens" do
      {:ok, sched} = Schedules.upsert_schedule(2024, "2024–2025")

      {:ok, r1} =
        Residents.insert_resident(sched.id, %{
          position_code: "R1-1",
          residency_year: 1,
          schedule_number: 1,
          name: "Alice"
        })

      {:ok, r2} =
        Residents.insert_resident(sched.id, %{
          position_code: "R1-2",
          residency_year: 1,
          schedule_number: 2,
          name: "Bob"
        })

      refute r1.calendar_token == r2.calendar_token
    end
  end

  describe "get_resident_by_token!/1" do
    test "returns the resident for a valid token", %{resident: resident} do
      found = Residents.get_resident_by_token!(resident.calendar_token)
      assert found.id == resident.id
      assert found.name == "Isolde"
    end

    test "raises for an unknown token" do
      assert_raise Ecto.NoResultsError, fn ->
        Residents.get_resident_by_token!("not-a-real-token")
      end
    end
  end
end
