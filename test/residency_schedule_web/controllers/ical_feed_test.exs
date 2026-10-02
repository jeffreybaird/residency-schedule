defmodule ResidencyScheduleWeb.IcalFeedTest do
  use ResidencyScheduleWeb.ConnCase

  alias ResidencySchedule.{Repo, Residents, Rotations, Schedules}
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

    {:ok, _} =
      Rotations.insert_rotations(resident.id, [
        %{
          slot_index: 0,
          start_date: ~D[2023-07-01],
          end_date: ~D[2023-07-14],
          rotation_type: :night_float
        }
      ])

    %{resident: resident, person: Repo.get!(Resident, resident.resident_id)}
  end

  describe "GET /feed/:token/calendar.ics" do
    test "returns iCal content for a valid token without authentication", %{
      conn: conn,
      person: person
    } do
      conn = get(conn, "/feed/#{person.calendar_token}/calendar.ics")
      assert response_content_type(conn, :ics) =~ "text/calendar"
      assert response(conn, 200) =~ "BEGIN:VCALENDAR"
      assert response(conn, 200) =~ "Isolde"
      assert response(conn, 200) =~ "20230701"
    end

    test "one token serves every academic year the person appears in", %{
      conn: conn,
      person: person
    } do
      {:ok, later} = Schedules.upsert_schedule(2024, "2024–2025")

      {:ok, later_sr} =
        Residents.insert_resident(later.id, %{
          position_code: "R4-2",
          residency_year: 4,
          schedule_number: 2,
          name: "Isolde"
        })

      {:ok, _} =
        Rotations.insert_rotations(later_sr.id, [
          %{
            slot_index: 0,
            start_date: ~D[2024-07-01],
            end_date: ~D[2024-07-14],
            rotation_type: :vacation
          }
        ])

      body = response(get(conn, "/feed/#{person.calendar_token}/calendar.ics"), 200)
      assert body =~ "20230701"
      assert body =~ "20240701"
    end

    test "raises for an invalid token", %{conn: conn} do
      assert_raise Ecto.NoResultsError, fn ->
        get(conn, "/feed/bad-token/calendar.ics")
      end
    end
  end

  describe "GET /residents/:id/calendar.ics" do
    setup :authenticate_session

    test "downloads the schedule resident's own year only", %{conn: conn, resident: resident} do
      conn = get(conn, "/residents/#{resident.id}/calendar.ics")
      assert response(conn, 200) =~ "BEGIN:VCALENDAR"

      assert get_resp_header(conn, "content-disposition") == [
               ~s(attachment; filename="Isolde.ics")
             ]
    end
  end
end
