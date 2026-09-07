defmodule ResidencyScheduleWeb.LayoutsTest do
  use ResidencySchedule.DataCase, async: true

  alias ResidencySchedule.{Accounts, Residents, Schedules}
  alias ResidencyScheduleWeb.Layouts

  doctest Layouts

  describe "nav_home_path/1" do
    setup do
      {:ok, s2023} = Schedules.upsert_schedule(2023, "2023–2024")
      {:ok, s2024} = Schedules.upsert_schedule(2024, "2024–2025")

      {:ok, sr_2023} =
        Residents.insert_resident(s2023.id, %{
          position_code: "R3-1",
          residency_year: 3,
          schedule_number: 1,
          name: "Briar"
        })

      {:ok, sr_2024} =
        Residents.insert_resident(s2024.id, %{
          position_code: "R4-1",
          residency_year: 4,
          schedule_number: 1,
          name: "Briar"
        })

      {:ok, user} = Accounts.create_user(%{email: "briar@urmc.rochester.edu"})
      %{user: user, sr_2023: sr_2023, sr_2024: sr_2024}
    end

    test "links to the person's most recent schedule appearance", %{
      user: user,
      sr_2023: sr_2023,
      sr_2024: sr_2024
    } do
      {:ok, user} = Accounts.set_home_resident(user, sr_2023.resident_id)
      assert Layouts.nav_home_path(user) == "/residents/#{sr_2024.id}"
    end

    test "returns nil when the person appears in no schedule", %{user: user} do
      {:ok, person} =
        %Residents.Resident{}
        |> Residents.Resident.changeset(%{name: "Nobody", calendar_token: Ecto.UUID.generate()})
        |> Repo.insert()

      {:ok, user} = Accounts.set_home_resident(user, person.id)
      assert Layouts.nav_home_path(user) == nil
    end

    test "returns nil without a home resident", %{user: user} do
      assert Layouts.nav_home_path(user) == nil
    end
  end
end
