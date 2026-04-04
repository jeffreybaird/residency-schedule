defmodule ResidencyScheduleWeb.IcalFeedTest do
  use ResidencyScheduleWeb.ConnCase

  alias ResidencySchedule.{Schedules, Residents, Rotations}

  setup do
    {:ok, sched} = Schedules.upsert_schedule(2023, "2023–2024")

    {:ok, resident} =
      Residents.insert_resident(sched.id, %{
        position_code: "R4-1",
        residency_year: 4,
        schedule_number: 1,
        name: "Clare"
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

    %{resident: resident}
  end

  describe "GET /feed/:token/calendar.ics" do
    test "returns iCal content for a valid token without authentication", %{
      conn: conn,
      resident: resident
    } do
      conn = get(conn, "/feed/#{resident.calendar_token}/calendar.ics")
      assert response_content_type(conn, :ics) =~ "text/calendar"
      assert response(conn, 200) =~ "BEGIN:VCALENDAR"
      assert response(conn, 200) =~ "Clare"
    end

    test "raises for an invalid token", %{conn: conn} do
      assert_raise Ecto.NoResultsError, fn ->
        get(conn, "/feed/bad-token/calendar.ics")
      end
    end
  end
end
