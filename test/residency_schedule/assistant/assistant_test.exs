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
      assert {:ok, %{person_id: person_id, position_code: "R3-1", schedule: "2026–2027"}} =
               Assistant.find_resident("tiff", "2026-07-10")

      assert person_id == tiff.resident_id
      refute Map.has_key?(elem(Assistant.find_resident("tiff", "2026-07-10"), 1), :id)
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

    test "whoami lists the loaded academic years with their dates", ctx do
      seed_prior_year_for_clare(ctx)
      assert {:ok, %{schedules: schedules}} = Assistant.whoami(ctx.clare_user)

      assert schedules == [
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
             ]
    end

    test "whoami describes the home resident", ctx do
      assert {:ok, %{role: :resident, home_resident: %{name: "Clare"} = home, today: %Date{}}} =
               Assistant.whoami(ctx.clare_user)

      assert home.person_id == ctx.clare.resident_id

      assert {:ok, %{role: :admin, home_resident: nil}} = Assistant.whoami(ctx.admin)
    end
  end

  describe "list_residents/1" do
    test "lists everyone in the current schedule", _ctx do
      assert {:ok, result} = Assistant.list_residents()
      assert result.academic_year == 2026
      assert result.residency_year == nil
      assert Enum.map(result.residents, & &1.position_code) == ["R2-1", "R2-2", "R3-1"]
    end

    test "reports the person id, shared by every year the person appears in", ctx do
      seed_prior_year_for_clare(ctx)

      {:ok, %{residents: current}} = Assistant.list_residents(%{academic_year: 2026})
      {:ok, %{residents: prior}} = Assistant.list_residents(%{academic_year: 2025})

      clare_now = Enum.find(current, &(&1.name == "Clare"))
      clare_then = Enum.find(prior, &(&1.name == "Clare"))

      assert clare_now.person_id == ctx.clare.resident_id
      assert clare_then.person_id == clare_now.person_id
      assert clare_then.position_code != clare_now.position_code
      refute Map.has_key?(clare_now, :id)
    end

    test "filters by residency year, accepting strings", _ctx do
      assert {:ok, %{count: 2, residency_year: 2}} =
               Assistant.list_residents(%{residency_year: 2})

      assert {:ok, %{count: 1, residents: [%{name: "Tiff"}]}} =
               Assistant.list_residents(%{residency_year: "3"})

      assert {:ok, %{count: 0}} = Assistant.list_residents(%{residency_year: 4})
    end

    test "selects a schedule by academic year", _ctx do
      {:ok, _} = Schedules.upsert_schedule(2025, "2025–2026")

      assert {:ok, %{academic_year: 2025, count: 0}} =
               Assistant.list_residents(%{academic_year: "2025"})

      assert {:ok, %{academic_year: 2026, count: 3}} =
               Assistant.list_residents(%{academic_year: 2026})

      assert {:error, {:schedule_not_found, 2019}} =
               Assistant.list_residents(%{academic_year: 2019})
    end

    test "rejects bad filters", _ctx do
      assert {:error, :invalid_residency_year} = Assistant.list_residents(%{residency_year: 7})

      assert {:error, :invalid_residency_year} =
               Assistant.list_residents(%{residency_year: "two"})

      assert {:error, :invalid_residency_year} = Assistant.list_residents(%{residency_year: 2.5})
      assert {:error, :invalid_academic_year} = Assistant.list_residents(%{academic_year: "next"})
    end

    test "errors with no schedule at all" do
      Repo.delete_all(Schedules.Schedule)
      assert {:error, :no_schedule} = Assistant.list_residents()
    end
  end

  describe "shared_shifts_by_coworker/3" do
    test "ranks every coworker, zeros included", _ctx do
      assert {:ok, result} = Assistant.shared_shifts_by_coworker("clare", "2026-07-06")
      assert result.resident.name == "Clare"

      assert Enum.map(result.coworkers, &{&1.coworker.name, &1.count}) == [
               {"Mary", 7},
               {"Tiff", 0}
             ]

      assert [%{rotation_type: "strong_obstetrics", days: 7}] = hd(result.coworkers).by_rotation
      assert "float" in result.counting_rule.working_days_not_shared
    end

    test "honours the range and coverage", ctx do
      tiff_ob = rotation_on(ctx.tiff, ~D[2026-07-15])

      {:ok, _} =
        ShiftOverrides.create_override(%{
          rotation_id: tiff_ob.id,
          covering_schedule_resident_id: ctx.clare.id,
          override_start_date: ~D[2026-07-15],
          override_end_date: ~D[2026-07-16]
        })

      assert {:ok,
              %{
                coworkers: [
                  %{coworker: %{name: "Mary"}, count: 2},
                  %{coworker: %{name: "Tiff"}, count: 0}
                ]
              }} =
               Assistant.shared_shifts_by_coworker("clare", "2026-07-13", "2026-07-19")
    end

    test "unknown resident" do
      assert {:error, {:resident_not_found, "Zed"}} =
               Assistant.shared_shifts_by_coworker("Zed", "2026-07-06")
    end
  end

  describe "shared_shift_matrix/1" do
    test "lists every pair, zeros included, matching the pairwise tool", _ctx do
      assert {:ok, result} = Assistant.shared_shift_matrix(%{from: "2026-07-06"})
      assert result.academic_year == 2026
      assert length(result.residents) == 3
      assert length(result.pairs) == 3

      # Clare/Mary share Strong OB Jul 6–12; Mary/Tiff share it Jul 13–19; Clare/Tiff never overlap.
      assert Enum.map(result.pairs, &{&1.resident.name, &1.coworker.name, &1.count}) == [
               {"Clare", "Mary", 7},
               {"Mary", "Tiff", 7},
               {"Clare", "Tiff", 0}
             ]

      for pair <- result.pairs do
        {:ok, %{count: count}} =
          Assistant.shared_shifts(pair.resident.name, pair.coworker.name, "2026-07-06")

        assert pair.count == count, "#{pair.resident.name}/#{pair.coworker.name}"
      end
    end

    test "honours range, coverage, and the class filter", ctx do
      tiff_ob = rotation_on(ctx.tiff, ~D[2026-07-15])

      {:ok, _} =
        ShiftOverrides.create_override(%{
          rotation_id: tiff_ob.id,
          covering_schedule_resident_id: ctx.clare.id,
          override_start_date: ~D[2026-07-15],
          override_end_date: ~D[2026-07-16]
        })

      assert {:ok, %{pairs: [%{resident: %{name: "Clare"}, coworker: %{name: "Mary"}, count: 2}]}} =
               Assistant.shared_shift_matrix(%{
                 from: "2026-07-13",
                 to: "2026-07-19",
                 residency_year: 2
               })

      # Tiff is off on the two covered days, so Mary/Tiff drop from 7 to 5.
      assert {:ok, %{pairs: pairs}} =
               Assistant.shared_shift_matrix(%{from: "2026-07-13", to: "2026-07-19"})

      assert Enum.map(pairs, &{&1.resident.name, &1.coworker.name, &1.count}) == [
               {"Mary", "Tiff", 5},
               {"Clare", "Mary", 2},
               {"Clare", "Tiff", 0}
             ]
    end

    test "selects the schedule by academic year and rejects bad input", _ctx do
      {:ok, _} = Schedules.upsert_schedule(2025, "2025–2026")

      assert {:ok, %{academic_year: 2025, pairs: [], residents: []}} =
               Assistant.shared_shift_matrix(%{academic_year: 2025})

      assert {:error, {:schedule_not_found, 2019}} =
               Assistant.shared_shift_matrix(%{academic_year: 2019})

      assert {:error, :invalid_residency_year} =
               Assistant.shared_shift_matrix(%{residency_year: 0})

      assert {:error, :invalid_date} = Assistant.shared_shift_matrix(%{from: "soon"})
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

  describe "shifts_remaining/3" do
    test "counts working days including solo rotations and coverage", ctx do
      assert {:ok, result} = Assistant.shifts_remaining("clare", "2026-07-06")
      assert result.count == 21
      assert result.counting_rule.not_shifts == ["vacation", "post_call"]

      tiff_ob = rotation_on(ctx.tiff, ~D[2026-07-15])

      {:ok, _} =
        ShiftOverrides.create_override(%{
          rotation_id: tiff_ob.id,
          covering_schedule_resident_id: ctx.clare.id,
          override_start_date: ~D[2026-07-15],
          override_end_date: ~D[2026-07-15]
        })

      assert {:ok, %{count: 21}} = Assistant.shifts_remaining("clare", "2026-07-06")
      assert {:ok, %{count: 20}} = Assistant.shifts_remaining("tiff", "2026-07-06")
    end

    test "excludes days off and honours the range", ctx do
      {:ok, _} =
        ResidencySchedule.Rotations.insert_rotations(ctx.clare.id, [
          %{
            slot_index: 3,
            start_date: ~D[2026-07-27],
            end_date: ~D[2026-08-02],
            rotation_type: :vacation
          }
        ])

      assert {:ok, %{count: 0}} = Assistant.shifts_remaining("clare", "2026-07-27")

      assert {:ok, %{count: 2, by_rotation: [%{rotation_type: "night_float", days: 2}]}} =
               Assistant.shifts_remaining("clare", "2026-07-25", "2026-07-31")
    end

    test "unknown resident" do
      assert {:error, {:resident_not_found, "Zed"}} =
               Assistant.shifts_remaining("Zed", "2026-07-06")
    end
  end

  describe "shared_shifts/4" do
    test "counts co-service days in range", _ctx do
      assert {:ok, result} = Assistant.shared_shifts("clare", "mary", "2026-07-06")
      assert result.count == 7
      assert [%{rotation_type: "strong_obstetrics", days: 7}] = result.by_rotation
      assert "float" in result.counting_rule.working_days_not_shared

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

  describe "shifts_remaining/3 across academic years" do
    setup ctx, do: seed_prior_year_for_clare(ctx)

    test "counts every year the person appears in, by year", _ctx do
      assert {:ok, result} = Assistant.shifts_remaining("clare", "2025-07-01")
      assert result.count == 35

      assert [
               %{
                 academic_year: 2025,
                 schedule: "2025–2026",
                 residency_year: 1,
                 position_code: "R1-1",
                 days: 14
               },
               %{
                 academic_year: 2026,
                 schedule: "2026–2027",
                 residency_year: 2,
                 position_code: "R2-1",
                 days: 21
               }
             ] = result.by_year

      assert Enum.find(result.by_rotation, &(&1.rotation_type == "oncology")).days == 7
    end

    test "a from date before any schedule still finds the person", _ctx do
      assert {:ok, %{count: 35, by_year: [_, _]}} =
               Assistant.shifts_remaining("clare", "2020-01-01")
    end

    test "the to date bounds the count to the earlier year", _ctx do
      assert {:ok, %{count: 14, by_year: [%{academic_year: 2025}]}} =
               Assistant.shifts_remaining("clare", "2025-07-01", "2025-12-31")
    end

    test "a range inside one year lists only that year", _ctx do
      assert {:ok, %{count: 21, by_year: [%{academic_year: 2026}]}} =
               Assistant.shifts_remaining("clare", "2026-07-06")
    end

    test "residents with one appearance are unaffected", _ctx do
      assert {:ok, %{count: 21, by_year: [%{academic_year: 2026, days: 21}]}} =
               Assistant.shifts_remaining("mary", "2026-07-06")
    end
  end

  describe "resident_schedule/3 across academic years" do
    setup ctx, do: seed_prior_year_for_clare(ctx)

    test "returns segments from every year in date order, each naming its schedule", _ctx do
      assert {:ok, %{segments: segments}} = Assistant.resident_schedule("clare", "2025-07-21")

      assert Enum.map(segments, &{&1.schedule, &1.rotation_type}) == [
               {"2025–2026", "night_float"},
               {"2026–2027", "strong_obstetrics"},
               {"2026–2027", "ambulatory"},
               {"2026–2027", "night_float"}
             ]
    end

    test "a range inside one year returns only that year", _ctx do
      assert {:ok, %{segments: segments}} =
               Assistant.resident_schedule("clare", "2026-07-14", "2026-07-21")

      assert Enum.map(segments, & &1.schedule) == ["2026–2027", "2026–2027"]
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
