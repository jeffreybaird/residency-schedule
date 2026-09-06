defmodule ResidencySchedule.AssistantTest do
  use ResidencySchedule.DataCase, async: true

  import ResidencySchedule.ScheduleFixtures

  alias ResidencySchedule.{Assistant, ChangeRequests, Schedules, ShiftOverrides}

  setup do
    fixtures = seed_mini_schedule()
    Map.merge(fixtures, %{clare_user: resident_user(fixtures.clare), admin: admin_user()})
  end

  describe "schedule_for/1 and Schedules.get_schedule_for_date/1" do
    test "finds the schedule spanning the date", %{schedule: schedule} do
      assert Schedules.get_schedule_for_date(~D[2026-07-10]).id == schedule.id
      assert Schedules.get_schedule_for_date(~D[2030-07-10]) == nil
      assert {:ok, %{id: id}} = Assistant.schedule_for(~D[2030-07-10])
      assert id == schedule.id
    end

    test "errors with no schedules at all" do
      Repo.delete_all(Schedules.Schedule)
      assert {:error, :no_schedule} = Assistant.schedule_for(~D[2026-07-10])
      assert {:error, :no_schedule} = Assistant.who_is_on("ob", "2026-07-10")
    end
  end

  describe "find_resident/2 and whoami/1" do
    test "resolves by first name", %{tiff: tiff} do
      assert {:ok, %{id: id, position_code: "R3-1", schedule: "2026–2027"}} =
               Assistant.find_resident("tiff", "2026-07-10")

      assert id == tiff.id
    end

    test "reports unknown and ambiguous names" do
      assert {:error, {:resident_not_found, "Zed"}} = Assistant.find_resident("Zed", "2026-07-10")

      {:ok, schedule} = Assistant.schedule_for(~D[2026-07-10])

      {:ok, _} =
        ResidencySchedule.Residents.insert_resident(schedule.id, %{
          position_code: "R1-1",
          residency_year: 1,
          schedule_number: 1,
          name: "Mary Beth"
        })

      assert {:ok, %{name: "Mary"}} = Assistant.find_resident("mary", "2026-07-10")

      assert {:error, {:ambiguous_resident, "mar", names}} =
               Assistant.find_resident("mar", "2026-07-10")

      assert Enum.sort(names) == ["Mary", "Mary Beth"]
    end

    test "rejects a bad date" do
      assert {:error, :invalid_date} = Assistant.find_resident("tiff", "yesterday")
    end

    test "whoami describes the home resident", ctx do
      assert {:ok, %{role: :resident, home_resident: %{name: "Clare"}, today: %Date{}}} =
               Assistant.whoami(ctx.clare_user)

      assert {:ok, %{role: :admin, home_resident: nil}} = Assistant.whoami(ctx.admin)
    end
  end

  describe "who_is_on/2" do
    test "lists residents on the service with coverage applied", ctx do
      assert {:ok, result} = Assistant.who_is_on("strong ob", "2026-07-15")
      assert result.rotation_type == "strong_obstetrics"
      assert Enum.map(result.assignments, & &1.name) == ["Mary", "Tiff"]

      tiff_ob = rotation_on(ctx.tiff, ~D[2026-07-15])

      {:ok, _} =
        ShiftOverrides.create_override(%{
          rotation_id: tiff_ob.id,
          covering_schedule_resident_id: ctx.clare.id,
          override_start_date: ~D[2026-07-15],
          override_end_date: ~D[2026-07-15]
        })

      assert {:ok, result} = Assistant.who_is_on("strong ob", "2026-07-15")
      names = Enum.map(result.assignments, &{&1.name, &1.is_coverage})
      assert {"Clare", true} in names
      refute Enum.any?(result.assignments, &(&1.name == "Tiff"))
    end

    test "weekends include weekend counterparts" do
      assert {:ok, result} = Assistant.who_is_on("ob", "2026-07-11")
      assert "strong_weekend_days" in result.rotation_types_included
      assert {:ok, weekday} = Assistant.who_is_on("ob", "2026-07-10")
      assert weekday.rotation_types_included == ["strong_obstetrics"]
    end

    test "unknown rotation" do
      assert {:error, :unknown_rotation} = Assistant.who_is_on("dermatology", "2026-07-10")
    end
  end

  describe "shared_shifts/4" do
    test "counts co-service days in range", _ctx do
      assert {:ok, result} = Assistant.shared_shifts("clare", "mary", "2026-07-06")
      assert result.count == 7
      assert [%{rotation_type: "strong_obstetrics", days: 7}] = result.by_rotation

      assert {:ok, result} = Assistant.shared_shifts("clare", "mary", "2026-07-10", "2026-07-11")
      assert result.count == 2
      assert result.dates == [~D[2026-07-10], ~D[2026-07-11]]
    end

    test "coverage adds shared days", ctx do
      tiff_ob = rotation_on(ctx.tiff, ~D[2026-07-15])

      {:ok, _} =
        ShiftOverrides.create_override(%{
          rotation_id: tiff_ob.id,
          covering_schedule_resident_id: ctx.clare.id,
          override_start_date: ~D[2026-07-15],
          override_end_date: ~D[2026-07-16]
        })

      assert {:ok, %{count: 2}} = Assistant.shared_shifts("clare", "mary", "2026-07-13")
    end

    test "unknown coworker" do
      assert {:error, {:resident_not_found, "Zed"}} =
               Assistant.shared_shifts("clare", "Zed", "2026-07-06")
    end
  end

  describe "resident_schedule/3" do
    test "returns clipped effective segments", _ctx do
      assert {:ok, result} = Assistant.resident_schedule("clare", "2026-07-14", "2026-07-21")
      assert Enum.map(result.segments, & &1.rotation_type) == ["ambulatory", "night_float"]
      assert hd(result.segments).rotation_label == "Ambulatory"
    end

    test "open-ended range", _ctx do
      assert {:ok, %{segments: segments}} = Assistant.resident_schedule("clare", "2026-07-20")
      assert length(segments) == 1
    end
  end

  describe "check_coverage/4" do
    test "valid cover reports duty hours", _ctx do
      assert {:ok, result} = Assistant.check_coverage("clare", "tiff", "2026-07-15", "2026-07-16")
      assert result.can_file
      assert result.problems == []
      assert result.shift.rotation_type == "strong_obstetrics"
      assert result.end_date == ~D[2026-07-16]
      refute result.duty_hours.violates
    end

    test "end date defaults to start date", _ctx do
      assert {:ok, %{start_date: d, end_date: d}} =
               Assistant.check_coverage("clare", "tiff", "2026-07-15")
    end

    test "reports filing problems without hiding duty hours", ctx do
      tiff_ob = rotation_on(ctx.tiff, ~D[2026-07-15])

      {:ok, _} =
        ShiftOverrides.create_override(%{
          rotation_id: tiff_ob.id,
          covering_schedule_resident_id: ctx.mary.id,
          override_start_date: ~D[2026-07-15],
          override_end_date: ~D[2026-07-15]
        })

      assert {:ok, result} = Assistant.check_coverage("clare", "tiff", "2026-07-15")
      refute result.can_file
      assert result.problems == [:already_covered]
      assert is_map(result.duty_hours)
    end

    test "range spanning two rotations is rejected", _ctx do
      assert {:ok, %{problems: [:dates_outside_rotation]}} =
               Assistant.check_coverage("clare", "tiff", "2026-07-12", "2026-07-13")
    end

    test "no rotation on that date", _ctx do
      assert {:error, {:no_rotation_on_date, "Tiff", ~D[2026-09-01]}} =
               Assistant.check_coverage("clare", "tiff", "2026-09-01")
    end

    test "bad end date", _ctx do
      assert {:error, :invalid_date} =
               Assistant.check_coverage("clare", "tiff", "2026-07-15", "never")
    end
  end

  describe "request_coverage/6" do
    test "files a pending request for an involved resident", ctx do
      assert {:ok, summary} =
               Assistant.request_coverage(
                 ctx.clare_user,
                 "clare",
                 "tiff",
                 "2026-07-15",
                 nil,
                 "please"
               )

      assert summary.status == :pending
      assert summary.covering_resident.name == "Clare"
      assert summary.original_resident.name == "Tiff"
      assert summary.note == "please"
      assert summary.requested_by == ctx.clare_user.email
      assert [_] = ChangeRequests.list_requests(ctx.admin, :pending)
    end

    test "forbidden for an uninvolved user", ctx do
      assert {:error, :forbidden} =
               Assistant.request_coverage(resident_user(ctx.mary), "clare", "tiff", "2026-07-15")
    end
  end
end
