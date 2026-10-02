defmodule ResidencySchedule.Residents.CalendarTokenTest do
  use ResidencySchedule.DataCase, async: true

  alias ResidencySchedule.{Repo, Residents, Schedules}
  alias ResidencySchedule.Residents.Resident

  setup do
    {:ok, sched} = Schedules.upsert_schedule(2023, "2023–2024")

    {:ok, resident} =
      Residents.insert_resident(sched.id, %{
        position_code: "R4-1",
        residency_year: 4,
        schedule_number: 1,
        name: "Isolde"
      })

    %{schedule: sched, resident: resident, person: Repo.get!(Resident, resident.resident_id)}
  end

  describe "insert_resident/2" do
    test "assigns a calendar_token to the person on insert", %{person: person} do
      assert person.calendar_token != nil
      assert String.length(person.calendar_token) > 0
    end

    test "two people get different tokens", %{schedule: sched, person: isolde} do
      {:ok, sr} =
        Residents.insert_resident(sched.id, %{
          position_code: "R1-1",
          residency_year: 1,
          schedule_number: 1,
          name: "Alice"
        })

      alice = Repo.get!(Resident, sr.resident_id)
      refute isolde.calendar_token == alice.calendar_token
    end

    test "the same person keeps one token across academic years", %{person: isolde} do
      {:ok, later} = Schedules.upsert_schedule(2024, "2024–2025")

      {:ok, sr} =
        Residents.insert_resident(later.id, %{
          position_code: "R4-3",
          residency_year: 4,
          schedule_number: 3,
          name: "Isolde"
        })

      assert sr.resident_id == isolde.id
      assert Repo.get!(Resident, sr.resident_id).calendar_token == isolde.calendar_token
    end

    test "the token survives deleting and recreating the schedule appearance", %{
      schedule: sched,
      person: isolde
    } do
      Repo.delete_all(ResidencySchedule.Residents.ScheduleResident)

      {:ok, sr} =
        Residents.insert_resident(sched.id, %{
          position_code: "R4-1",
          residency_year: 4,
          schedule_number: 1,
          name: "Isolde"
        })

      assert sr.resident_id == isolde.id
      assert Repo.get!(Resident, isolde.id).calendar_token == isolde.calendar_token
    end
  end

  describe "get_person_by_token!/1" do
    test "returns the person for a valid token", %{person: person} do
      found = Residents.get_person_by_token!(person.calendar_token)
      assert found.id == person.id
      assert found.name == "Isolde"
    end

    test "raises for an unknown token" do
      assert_raise Ecto.NoResultsError, fn ->
        Residents.get_person_by_token!("not-a-real-token")
      end
    end
  end
end
