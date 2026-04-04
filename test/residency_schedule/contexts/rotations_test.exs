defmodule ResidencySchedule.RotationsTest do
  use ResidencySchedule.DataCase, async: true

  alias ResidencySchedule.{Residents, Rotations, Schedules}

  setup do
    {:ok, sched} = Schedules.upsert_schedule(2023, "2023–2024")

    {:ok, ra} =
      Residents.insert_resident(sched.id, %{
        position_code: "R4-1",
        residency_year: 4,
        schedule_number: 1,
        name: "Alexis"
      })

    {:ok, rb} =
      Residents.insert_resident(sched.id, %{
        position_code: "R4-2",
        residency_year: 4,
        schedule_number: 2,
        name: "Emily"
      })

    rots_a = [
      %{
        slot_index: 0,
        start_date: ~D[2023-07-03],
        end_date: ~D[2023-07-07],
        rotation_type: :oncology
      },
      %{
        slot_index: 1,
        start_date: ~D[2023-07-08],
        end_date: ~D[2023-07-09],
        rotation_type: :highland_weekend_days
      }
    ]

    rots_b = [
      %{
        slot_index: 0,
        start_date: ~D[2023-07-03],
        end_date: ~D[2023-07-07],
        rotation_type: :night_float
      },
      %{
        slot_index: 1,
        start_date: ~D[2023-07-08],
        end_date: ~D[2023-07-09],
        rotation_type: :post_call
      }
    ]

    {:ok, _} = Rotations.insert_rotations(ra.id, rots_a)
    {:ok, _} = Rotations.insert_rotations(rb.id, rots_b)

    %{schedule: sched, ra: ra, rb: rb}
  end

  describe "rotation_type_label/1" do
    test "returns human-readable label for known type" do
      assert Rotations.rotation_type_label("oncology") == "Oncology"
      assert Rotations.rotation_type_label("night_float") == "Night Float – Strong"
    end

    test "returns the raw string for unknown type" do
      assert Rotations.rotation_type_label("unknown_xyz") == "unknown_xyz"
    end
  end

  describe "rotation_type_color/1" do
    test "returns Tailwind classes for known type" do
      assert Rotations.rotation_type_color("oncology") == "bg-rose-700 text-white"
    end

    test "returns fallback gray for unknown type" do
      assert Rotations.rotation_type_color("unknown_xyz") == "bg-gray-200 text-gray-600"
    end
  end

  describe "all_rotation_types/0" do
    test "includes all expected rotation types" do
      types = Rotations.all_rotation_types()
      assert "oncology" in types
      assert "night_float" in types
      assert "vacation" in types
    end
  end

  describe "list_rotations_for_resident/1" do
    test "returns rotations ordered by start_date", %{ra: ra} do
      rotations = Rotations.list_rotations_for_resident(ra.id)
      assert length(rotations) == 2
      assert hd(rotations).start_date == ~D[2023-07-03]
    end

    test "returns empty list for resident with no rotations", %{schedule: sched} do
      {:ok, new_res} =
        Residents.insert_resident(sched.id, %{
          position_code: "R1-1",
          residency_year: 1,
          schedule_number: 1,
          name: "New"
        })

      assert Rotations.list_rotations_for_resident(new_res.id) == []
    end
  end

  describe "insert_rotations/2" do
    test "inserts multiple rotations and returns count", %{schedule: sched} do
      {:ok, new_res} =
        Residents.insert_resident(sched.id, %{
          position_code: "R3-1",
          residency_year: 3,
          schedule_number: 1,
          name: "Sam"
        })

      rots = [
        %{
          slot_index: 0,
          start_date: ~D[2023-07-03],
          end_date: ~D[2023-07-07],
          rotation_type: :ambulatory
        }
      ]

      {:ok, count} = Rotations.insert_rotations(new_res.id, rots)
      assert count == 1
    end

    test "inserting zero rotations returns count of 0", %{schedule: sched} do
      {:ok, new_res} =
        Residents.insert_resident(sched.id, %{
          position_code: "R3-2",
          residency_year: 3,
          schedule_number: 2,
          name: "Robin"
        })

      {:ok, count} = Rotations.insert_rotations(new_res.id, [])
      assert count == 0
    end
  end

  describe "list_rotations_for_schedule_type_in_range/4" do
    test "returns all residents on the schedule with that type overlapping the range", %{
      schedule: sched,
      ra: ra
    } do
      {:ok, rc} =
        Residents.insert_resident(sched.id, %{
          position_code: "R4-9",
          residency_year: 4,
          schedule_number: 9,
          name: "CoOnc"
        })

      {:ok, _} =
        Rotations.insert_rotations(rc.id, [
          %{
            slot_index: 0,
            start_date: ~D[2023-07-04],
            end_date: ~D[2023-07-06],
            rotation_type: :oncology
          }
        ])

      rots =
        Rotations.list_rotations_for_schedule_type_in_range(
          sched.id,
          "oncology",
          ~D[2023-07-03],
          ~D[2023-07-07]
        )

      ids = rots |> Enum.map(& &1.schedule_resident_id) |> Enum.sort()
      assert ra.id in ids
      assert rc.id in ids
      assert Enum.all?(rots, &(&1.rotation_type == "oncology"))
    end

    test "returns empty when no rotation of that type overlaps", %{schedule: sched} do
      assert Rotations.list_rotations_for_schedule_type_in_range(
               sched.id,
               "oncology",
               ~D[2020-01-01],
               ~D[2020-01-07]
             ) == []
    end
  end

  describe "effective_day_assignments/2" do
    alias ResidencySchedule.Residents.ScheduleResident
    alias ResidencySchedule.Rotations.Rotation
    alias ResidencySchedule.ShiftOverrides.ShiftOverride

    test "returns one row per rotation when there are no overrides" do
      a = %ScheduleResident{
        id: 1,
        residency_year: 4,
        schedule_number: 1,
        position_code: "R4-1",
        name: "Ann"
      }

      rot = %Rotation{
        id: 5,
        rotation_type: "oncology",
        schedule_resident_id: 1,
        schedule_resident: a
      }

      [row] = Rotations.effective_day_assignments([rot], [])
      assert row.resident == a
      refute row.overridden
      refute row.is_coverage
    end

    test "suppresses the covering resident's own rotation but keeps coverage rows" do
      a = %ScheduleResident{id: 1, residency_year: 4, schedule_number: 1, name: "Ann"}
      b = %ScheduleResident{id: 2, residency_year: 2, schedule_number: 1, name: "Bea"}

      rot_a = %Rotation{
        id: 10,
        rotation_type: "oncology",
        schedule_resident_id: 1,
        schedule_resident: a
      }

      rot_b = %Rotation{
        id: 11,
        rotation_type: "elective",
        schedule_resident_id: 2,
        schedule_resident: b
      }

      ov = %ShiftOverride{
        rotation_id: 10,
        covering_schedule_resident_id: 2,
        covering_schedule_resident: b,
        override_start_date: ~D[2023-07-01],
        override_end_date: ~D[2023-07-07]
      }

      rows = Rotations.effective_day_assignments([rot_a, rot_b], [ov])

      assert length(rows) == 2
      refute Enum.any?(rows, fn r -> r.rotation_type == "elective" end)
      assert Enum.count(rows, & &1.is_coverage) == 1
      assert Enum.any?(rows, fn r -> r.overridden and r.resident.id == a.id end)
    end
  end

  describe "list_off_coworker_rows_for_slot_in_range/4" do
    test "lists residents with no rotation for that slot and range", %{
      schedule: sched,
      ra: ra,
      rb: rb
    } do
      {:ok, on_service} =
        Residents.insert_resident(sched.id, %{
          position_code: "R4-9",
          residency_year: 4,
          schedule_number: 9,
          name: "OnCall"
        })

      {:ok, _} =
        Rotations.insert_rotations(on_service.id, [
          %{
            slot_index: 2,
            start_date: ~D[2023-07-03],
            end_date: ~D[2023-07-07],
            rotation_type: :oncology
          }
        ])

      rows =
        Rotations.list_off_coworker_rows_for_slot_in_range(
          sched.id,
          2,
          ~D[2023-07-03],
          ~D[2023-07-07]
        )

      ids = Enum.map(rows, & &1.resident.id)

      assert ra.id in ids
      assert rb.id in ids
      refute on_service.id in ids

      row_ra = Enum.find(rows, &(&1.resident.id == ra.id))
      assert MapSet.size(row_ra.active_dates) == 5
    end
  end

  describe "format_date_set_within_block/3" do
    test "formats a single day without a range dash" do
      dates = MapSet.new([~D[2023-07-03]])

      assert Rotations.format_date_set_within_block(dates, ~D[2023-07-01], ~D[2023-07-31]) ==
               "Jul 3, 2023"
    end
  end

  describe "list_effective_coworker_rows_for_type_in_range/4" do
    alias ResidencySchedule.ShiftOverrides

    setup do
      {:ok, sched} = Schedules.upsert_schedule(2023, "2023–2024")

      {:ok, clare} =
        Residents.insert_resident(sched.id, %{
          position_code: "R4-8",
          residency_year: 4,
          schedule_number: 8,
          name: "Clare"
        })

      {:ok, emily} =
        Residents.insert_resident(sched.id, %{
          position_code: "R2-8",
          residency_year: 2,
          schedule_number: 8,
          name: "EmilyCov"
        })

      {:ok, _} =
        Rotations.insert_rotations(clare.id, [
          %{
            slot_index: 0,
            start_date: ~D[2023-07-01],
            end_date: ~D[2023-07-14],
            rotation_type: :night_float
          }
        ])

      {:ok, _} =
        Rotations.insert_rotations(emily.id, [
          %{
            slot_index: 0,
            start_date: ~D[2023-07-01],
            end_date: ~D[2023-07-14],
            rotation_type: :elective
          }
        ])

      clares_rotation = Rotations.list_rotations_for_resident(clare.id) |> hd()

      %{
        sched: sched,
        clare: clare,
        emily: emily,
        clares_rotation: clares_rotation
      }
    end

    test "lists coverage row when override overlaps the range", %{
      sched: sched,
      clare: clare,
      emily: emily,
      clares_rotation: rot
    } do
      {:ok, _} =
        ShiftOverrides.create_override(%{
          rotation_id: rot.id,
          covering_schedule_resident_id: emily.id,
          override_start_date: ~D[2023-07-08],
          override_end_date: ~D[2023-07-14]
        })

      rows =
        Rotations.list_effective_coworker_rows_for_type_in_range(
          sched.id,
          "night_float",
          ~D[2023-07-08],
          ~D[2023-07-10]
        )

      coverage = Enum.find(rows, & &1.is_coverage)
      assert coverage.resident.id == emily.id
      assert MapSet.size(coverage.active_dates) == 3

      clare_overridden = Enum.find(rows, fn r -> r.resident.id == clare.id && r.overridden end)

      assert clare_overridden
      assert clare_overridden.covered_by.id == emily.id
    end
  end

  describe "list_rotations_for_date/2" do
    test "returns rotations covering the given date", %{schedule: sched} do
      rotations = Rotations.list_rotations_for_date(~D[2023-07-05], sched.id)
      assert length(rotations) == 2
      types = Enum.map(rotations, & &1.rotation_type)
      assert "oncology" in types
      assert "night_float" in types
    end

    test "returns empty list for a date with no rotations", %{schedule: sched} do
      assert Rotations.list_rotations_for_date(~D[2022-01-01], sched.id) == []
    end
  end

  describe "list_rotations_for_month_all_schedules/2" do
    test "returns rotations from all schedules that overlap the given month", %{schedule: _sched} do
      # ra has oncology 2023-07-03..07-07, rb has night_float same dates — both in July 2023
      rotations = Rotations.list_rotations_for_month_all_schedules(2023, 7)
      types = Enum.map(rotations, & &1.rotation_type)
      assert "oncology" in types
      assert "night_float" in types
    end

    test "returns rotations from a second schedule in the same month", %{} do
      {:ok, sched2} = Schedules.upsert_schedule(2024, "2024–2025")

      {:ok, res2} =
        Residents.insert_resident(sched2.id, %{
          position_code: "R1-1",
          residency_year: 1,
          schedule_number: 1,
          name: "Jordan"
        })

      rots = [
        %{
          slot_index: 0,
          start_date: ~D[2024-07-01],
          end_date: ~D[2024-07-14],
          rotation_type: :ambulatory
        }
      ]

      {:ok, _} = Rotations.insert_rotations(res2.id, rots)

      rotations = Rotations.list_rotations_for_month_all_schedules(2024, 7)
      assert Enum.any?(rotations, &(&1.rotation_type == "ambulatory"))
    end

    test "returns empty list when no rotations overlap the given month" do
      assert Rotations.list_rotations_for_month_all_schedules(2000, 1) == []
    end

    test "preloads schedule_resident association", %{ra: _ra} do
      [rot | _] = Rotations.list_rotations_for_month_all_schedules(2023, 7)
      assert %ResidencySchedule.Residents.ScheduleResident{} = rot.schedule_resident
    end
  end

  describe "list_co_service_days/2" do
    test "excludes float and post_call rotations", %{schedule: sched} do
      {:ok, r3} =
        Residents.insert_resident(sched.id, %{
          position_code: "R3-1",
          residency_year: 3,
          schedule_number: 1,
          name: "Pat"
        })

      float_rots = [
        %{
          slot_index: 10,
          start_date: ~D[2023-08-01],
          end_date: ~D[2023-08-07],
          rotation_type: :float
        }
      ]

      {:ok, _} = Rotations.insert_rotations(r3.id, float_rots)

      # Add matching float rotation to ra — should be excluded
      more_a = [
        %{
          slot_index: 10,
          start_date: ~D[2023-08-01],
          end_date: ~D[2023-08-07],
          rotation_type: :float
        }
      ]

      {:ok, _} =
        Rotations.insert_rotations(Residents.get_resident_by_position!("R4-1").id, more_a)

      # ra and r3 both have float on same dates — should NOT appear in co-service
      ra = Residents.get_resident_by_position!("R4-1")
      days = Rotations.list_co_service_days(ra.id, r3.id)
      float_days = Enum.filter(days, &(&1.rotation_type == "float"))
      assert float_days == []
    end

    test "excludes elective rotations", %{schedule: sched} do
      {:ok, rc} =
        Residents.insert_resident(sched.id, %{
          position_code: "R2-1",
          residency_year: 2,
          schedule_number: 1,
          name: "Morgan"
        })

      elective_rots = [
        %{
          slot_index: 11,
          start_date: ~D[2023-09-01],
          end_date: ~D[2023-09-07],
          rotation_type: :elective
        }
      ]

      {:ok, _} = Rotations.insert_rotations(rc.id, elective_rots)

      {:ok, rd} =
        Residents.insert_resident(sched.id, %{
          position_code: "R2-2",
          residency_year: 2,
          schedule_number: 2,
          name: "Quinn"
        })

      {:ok, _} = Rotations.insert_rotations(rd.id, elective_rots)

      days = Rotations.list_co_service_days(rc.id, rd.id)
      elective_days = Enum.filter(days, &(&1.rotation_type == "elective"))
      assert elective_days == []
    end

    test "returns days where two residents share the same service", %{ra: ra, rb: rb} do
      # ra and rb both have rotations on 2023-07-03 to 2023-07-07, but different types
      # so no co-service days from setup
      days = Rotations.list_co_service_days(ra.id, rb.id)
      assert is_list(days)
    end
  end
end
