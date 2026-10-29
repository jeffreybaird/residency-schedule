defmodule ResidencySchedule.EffectiveScheduleTest do
  use ResidencySchedule.DataCase, async: true

  alias ResidencySchedule.DetailedSchedules.{Activity, ActivitySource, ImportBatch}

  alias ResidencySchedule.{
    EffectiveSchedule,
    Ical,
    Residents,
    Rotations,
    ScheduleFixtures,
    Schedules,
    ShiftOverrides
  }

  @date_only %{precision: :date_only, period: nil}
  @first_day ~D[2026-07-06]
  @last_day ~D[2026-07-26]

  # Synthetic 2026–2027 roster. Ada has no third block, so Jul 20–26 are blank
  # except for two imported gap-fill days. Cal covers Bea's elective on Jul 15–16.
  #
  # | Resident | Jul 6–12          | Jul 13–19  | Jul 20–26                       |
  # |----------|-------------------|------------|---------------------------------|
  # | Ada      | strong_obstetrics | ambulatory | gap fill Jul 21, vacation Jul 22|
  # | Bea      | strong_obstetrics | elective   | leave_of_absence                |
  # | Cal      | oncology          | strong_obstetrics Jul 13–26                  |
  setup do
    {:ok, schedule} = Schedules.upsert_schedule(2026, "2026–2027")
    ada = insert_resident(schedule, "Ada", "R2-1", 2, 1)
    bea = insert_resident(schedule, "Bea", "R2-2", 2, 2)
    cal = insert_resident(schedule, "Cal", "R3-1", 3, 1)

    insert_blocks(ada, [
      {:strong_obstetrics, ~D[2026-07-06], ~D[2026-07-12]},
      {:ambulatory, ~D[2026-07-13], ~D[2026-07-19]}
    ])

    insert_blocks(bea, [
      {:strong_obstetrics, ~D[2026-07-06], ~D[2026-07-12]},
      {:elective, ~D[2026-07-13], ~D[2026-07-19]},
      {:leave_of_absence, ~D[2026-07-20], ~D[2026-07-26]}
    ])

    insert_blocks(cal, [
      {:oncology, ~D[2026-07-06], ~D[2026-07-12]},
      {:strong_obstetrics, ~D[2026-07-13], ~D[2026-07-26]}
    ])

    elective = Rotations.get_rotation_for_resident_on_date(bea.id, ~D[2026-07-15])

    {:ok, _} =
      ShiftOverrides.create_override(%{
        rotation_id: elective.id,
        covering_schedule_resident_id: cal.id,
        override_start_date: ~D[2026-07-15],
        override_end_date: ~D[2026-07-16]
      })

    add_activity(ada, ~D[2026-07-21], "Mystery Clinic PM")
    add_activity(ada, ~D[2026-07-21], "Another Task")
    add_activity(ada, ~D[2026-07-22], "Vacation")

    %{schedule: schedule, ada: ada, bea: bea, cal: cal}
  end

  describe "for_schedule/2" do
    test "returns one record per resident and date across the schedule's range, sorted", ctx do
      assert {:ok, records} = EffectiveSchedule.for_schedule(ctx.schedule.id, :legacy)
      assert length(records) == 63

      assert Enum.map(records, &{&1.schedule_resident_id, Date.to_gregorian_days(&1.date)}) ==
               Enum.sort(
                 Enum.map(records, &{&1.schedule_resident_id, Date.to_gregorian_days(&1.date)})
               )

      for resident <- [ctx.ada, ctx.bea, ctx.cal] do
        own = Enum.filter(records, &(&1.schedule_resident_id == resident.id))
        assert Enum.map(own, & &1.date) == Enum.to_list(Date.range(@first_day, @last_day))
        assert Enum.all?(own, &(&1.person_id == resident.resident_id))
        assert Enum.all?(own, &(&1.schedule_id == ctx.schedule.id))
      end
    end

    test "a plain rotation day is one working rotation duty", ctx do
      assert record(ctx, ctx.ada, ~D[2026-07-07]) == %{
               person_id: ctx.ada.resident_id,
               schedule_resident_id: ctx.ada.id,
               schedule_id: ctx.schedule.id,
               date: ~D[2026-07-07],
               duties: [
                 %{
                   kind: :rotation,
                   code: "strong_obstetrics",
                   label: "Obstetrics – Strong",
                   status: :working,
                   source_tasks: [],
                   timing: @date_only,
                   covered_by_person_id: nil,
                   original_person_id: nil,
                   source_assignment_date: nil
                 }
               ],
               off: nil
             }
    end

    test "a coverage override marks the original covered and the cover as coverage", ctx do
      for date <- [~D[2026-07-15], ~D[2026-07-16]] do
        assert %{duties: [bea_duty], off: nil} = record(ctx, ctx.bea, date)
        assert bea_duty.kind == :rotation
        assert bea_duty.code == "elective"
        assert bea_duty.status == :covered
        assert bea_duty.covered_by_person_id == ctx.cal.resident_id
        assert bea_duty.original_person_id == nil

        assert %{duties: [cal_duty], off: nil} = record(ctx, ctx.cal, date)
        assert cal_duty.kind == :coverage
        assert cal_duty.code == "elective"
        assert cal_duty.label == "Elective"
        assert cal_duty.status == :working
        assert cal_duty.original_person_id == ctx.bea.resident_id
        assert cal_duty.covered_by_person_id == nil
        assert cal_duty.source_tasks == []
        assert cal_duty.source_assignment_date == nil
        assert cal_duty.timing == @date_only
      end

      for date <- [~D[2026-07-14], ~D[2026-07-17]] do
        assert [%{kind: :rotation, code: "strong_obstetrics", status: :working}] =
                 record(ctx, ctx.cal, date).duties

        assert [%{kind: :rotation, code: "elective", status: :working, covered_by_person_id: nil}] =
                 record(ctx, ctx.bea, date).duties
      end
    end

    test "an imported day without a rotation is a gap-fill duty with its tasks", ctx do
      assert record(ctx, ctx.ada, ~D[2026-07-21]) == %{
               person_id: ctx.ada.resident_id,
               schedule_resident_id: ctx.ada.id,
               schedule_id: ctx.schedule.id,
               date: ~D[2026-07-21],
               duties: [
                 %{
                   kind: :gap_fill,
                   code: "qgenda_assignment",
                   label: "Mystery Clinic PM; Another Task",
                   status: :working,
                   source_tasks: ["Mystery Clinic PM", "Another Task"],
                   timing: @date_only,
                   covered_by_person_id: nil,
                   original_person_id: nil,
                   source_assignment_date: ~D[2026-07-21]
                 }
               ],
               off: nil
             }
    end

    test "vacation and leave days are :off duties with the matching off state", ctx do
      assert %{duties: [vacation], off: :vacation} = record(ctx, ctx.ada, ~D[2026-07-22])
      assert vacation.kind == :gap_fill
      assert vacation.code == "vacation"
      assert vacation.label == "Vacation"
      assert vacation.status == :off
      assert vacation.source_tasks == ["Vacation"]
      assert vacation.source_assignment_date == ~D[2026-07-22]

      assert %{duties: [leave], off: :leave} = record(ctx, ctx.bea, ~D[2026-07-20])
      assert leave.kind == :rotation
      assert leave.code == "leave_of_absence"
      assert leave.label == "Leave of Absence"
      assert leave.status == :off
    end

    test "a day with nothing scheduled is blank", ctx do
      for date <- [~D[2026-07-20], ~D[2026-07-23], ~D[2026-07-26]] do
        assert record(ctx, ctx.ada, date) == %{
                 person_id: ctx.ada.resident_id,
                 schedule_resident_id: ctx.ada.id,
                 schedule_id: ctx.schedule.id,
                 date: date,
                 duties: [],
                 off: :blank
               }
      end
    end

    test "a gap-fill day outside every stored block extends the schedule range", ctx do
      add_activity(ctx.cal, ~D[2026-07-28], "Mystery Clinic PM")
      assert {:ok, records} = EffectiveSchedule.for_schedule(ctx.schedule.id, :legacy)
      assert length(records) == 69
      assert [%{kind: :gap_fill}] = record(ctx, ctx.cal, ~D[2026-07-28]).duties
      assert record(ctx, ctx.ada, ~D[2026-07-28]).off == :blank
      assert record(ctx, ctx.bea, ~D[2026-07-27]).off == :blank
    end

    test ":v2 preserves base duties but exposes missing activity evidence as neutral duties",
         ctx do
      assert {:ok, legacy} = EffectiveSchedule.for_schedule(ctx.schedule.id, :legacy)
      assert {:ok, v2} = EffectiveSchedule.for_schedule(ctx.schedule.id, :v2)

      changed = fn record ->
        record.schedule_resident_id == ctx.ada.id and
          record.date in [~D[2026-07-21], ~D[2026-07-22]]
      end

      assert Enum.reject(v2, changed) == Enum.reject(legacy, changed)
      assert [%{duties: unknown}, %{duties: [vacation], off: nil}] = Enum.filter(v2, changed)
      assert Enum.map(unknown, & &1.label) |> Enum.sort() == ["Another Task", "Mystery Clinic PM"]
      assert Enum.all?(unknown, &(&1.code == "qgenda_assignment"))
      assert vacation.code == "qgenda_assignment"
      assert vacation.label == "Vacation"
      assert {:ok, diagnostics} = EffectiveSchedule.evidence_diagnostics(ctx.schedule.id, :v2)
      assert length(diagnostics) == 9

      assert Enum.frequencies_by(diagnostics, & &1.reason) == %{
               missing_identity: 3,
               missing_classification: 3,
               missing_timing: 3
             }
    end

    test "an unknown schedule is :not_found and an unknown version is rejected", ctx do
      assert EffectiveSchedule.for_schedule(-1, :legacy) == {:error, :not_found}
      assert EffectiveSchedule.for_schedule(ctx.schedule.id, :v3) == {:error, :unknown_version}

      assert EffectiveSchedule.for_schedule(ctx.schedule.id, "legacy") ==
               {:error, :unknown_version}
    end

    test "a schedule with residents but no rotations has no records" do
      {:ok, empty} = Schedules.upsert_schedule(2030, "2030–2031")
      _resident = insert_resident(empty, "Dee", "R1-1", 1, 1)
      assert EffectiveSchedule.for_schedule(empty.id, :legacy) == {:ok, []}
      assert EffectiveSchedule.for_schedule(empty.id, :v2) == {:ok, []}
    end
  end

  describe "for_date/3" do
    test "returns the records for that date only, one per resident", ctx do
      assert {:ok, records} = EffectiveSchedule.for_date(ctx.schedule.id, ~D[2026-07-15], :legacy)

      assert Enum.map(records, & &1.schedule_resident_id) ==
               Enum.sort([ctx.ada.id, ctx.bea.id, ctx.cal.id])

      assert Enum.all?(records, &(&1.date == ~D[2026-07-15]))

      assert Enum.find(records, &(&1.schedule_resident_id == ctx.bea.id)) ==
               record(ctx, ctx.bea, ~D[2026-07-15])

      assert EffectiveSchedule.for_date(ctx.schedule.id, ~D[2026-07-15], :v2) == {:ok, records}
    end

    test "a date outside the schedule range has no records", ctx do
      assert EffectiveSchedule.for_date(ctx.schedule.id, ~D[2026-08-15], :legacy) == {:ok, []}
    end

    test "propagates not found and unknown version", ctx do
      assert EffectiveSchedule.for_date(-1, ~D[2026-07-15], :legacy) == {:error, :not_found}

      assert EffectiveSchedule.for_date(ctx.schedule.id, ~D[2026-07-15], :nope) ==
               {:error, :unknown_version}
    end
  end

  describe "for_person/2" do
    test "spans every schedule appearance of the person, sorted by schedule then date", ctx do
      %{prior_schedule: prior, clare_r1: earlier} =
        ScheduleFixtures.seed_prior_year_for_clare(%{clare: ctx.ada})

      assert earlier.resident_id == ctx.ada.resident_id

      assert {:ok, records} = EffectiveSchedule.for_person(ctx.ada.resident_id, :legacy)
      assert length(records) == 42
      assert Enum.all?(records, &(&1.person_id == ctx.ada.resident_id))

      keys = Enum.map(records, &{&1.schedule_id, Date.to_gregorian_days(&1.date)})
      assert keys == Enum.sort(keys)

      assert Enum.map(records, & &1.schedule_id) |> Enum.uniq() |> Enum.sort() ==
               Enum.sort([ctx.schedule.id, prior.id])

      {:ok, current} = EffectiveSchedule.for_schedule(ctx.schedule.id, :legacy)
      {:ok, previous} = EffectiveSchedule.for_schedule(prior.id, :legacy)

      assert Enum.filter(records, &(&1.schedule_id == ctx.schedule.id)) ==
               Enum.filter(current, &(&1.schedule_resident_id == ctx.ada.id))

      assert Enum.filter(records, &(&1.schedule_id == prior.id)) == previous
      assert Enum.find(previous, &(&1.date == ~D[2025-07-15])).off == :vacation
      assert {:ok, v2_records} = EffectiveSchedule.for_person(ctx.ada.resident_id, :v2)
      assert Enum.filter(v2_records, &(&1.schedule_id == prior.id)) == previous
      assert {:ok, v2_current} = EffectiveSchedule.for_schedule(ctx.schedule.id, :v2)

      assert Enum.filter(v2_records, &(&1.schedule_id == ctx.schedule.id)) ==
               Enum.filter(v2_current, &(&1.schedule_resident_id == ctx.ada.id))

      assert Enum.find(v2_records, &(&1.date == ~D[2026-07-22])).off == nil
    end

    test "a person in one schedule gets only that schedule's records", ctx do
      assert {:ok, records} = EffectiveSchedule.for_person(ctx.bea.resident_id, :legacy)
      assert length(records) == 21
      assert Enum.all?(records, &(&1.schedule_resident_id == ctx.bea.id))
    end

    test "an unknown person has no records and an unknown version is rejected", ctx do
      assert EffectiveSchedule.for_person(-1, :legacy) == {:ok, []}

      assert EffectiveSchedule.for_person(ctx.ada.resident_id, :nope) ==
               {:error, :unknown_version}
    end
  end

  describe "calendar_events/2" do
    test "returns the feed identity set for every appearance, sorted by start then uid", ctx do
      %{prior_schedule: _prior} = ScheduleFixtures.seed_prior_year_for_clare(%{clare: ctx.ada})
      assert {:ok, events} = EffectiveSchedule.calendar_events(ctx.ada.resident_id, :legacy)

      # 2025: 7 oncology days, 1 vacation block, 7 night float nights.
      # 2026: 7 strong OB days, 7 ambulatory days, 1 gap-fill day, 1 vacation day.
      assert length(events) == 31

      assert Enum.all?(
               events,
               &(Map.keys(&1) |> Enum.sort() == [:dtend, :dtstart, :summary, :uid])
             )

      keys = Enum.map(events, &{&1.dtstart, &1.uid})
      assert keys == Enum.sort(keys)

      assert hd(events) == %{
               uid: "seg-oncology-2025-07-07-2025-07-07@residency-schedule",
               dtstart: "20250707T060000",
               dtend: "20250707T180000",
               summary: "Oncology"
             }

      assert %{
               uid: "seg-vacation-2025-07-14@residency-schedule",
               dtstart: "20250714",
               dtend: "20250720",
               summary: "Vacation"
             } in events

      assert %{
               uid: "seg-night_float-2025-07-21-2025-07-21@residency-schedule",
               dtstart: "20250720T180000",
               dtend: "20250721T060000",
               summary: "Night Float – Strong"
             } in events

      assert %{
               uid: "seg-qgenda_assignment-2026-07-21@residency-schedule",
               dtstart: "20260721",
               dtend: "20260722",
               summary: "Mystery Clinic PM\\; Another Task"
             } in events

      assert %{
               uid: "seg-vacation-2026-07-22@residency-schedule",
               dtstart: "20260722",
               dtend: "20260723",
               summary: "Vacation"
             } in events

      person = Repo.get!(ResidencySchedule.Residents.Resident, ctx.ada.resident_id)

      expected =
        person.id
        |> Rotations.effective_segments_for_person()
        |> Ical.events_from_segments(person.name)
        |> Enum.sort_by(&{&1.dtstart, &1.uid})

      assert events == expected
      assert {:ok, v2_events} = EffectiveSchedule.calendar_events(ctx.ada.resident_id, :v2)
      activity_day = &(&1.dtstart in ["20260721", "20260722"])
      assert Enum.reject(v2_events, activity_day) == Enum.reject(events, activity_day)
      activity_events = Enum.filter(v2_events, activity_day)
      assert length(activity_events) == 3

      assert Enum.map(activity_events, & &1.summary) |> Enum.sort() == [
               "Another Task",
               "Mystery Clinic PM",
               "Vacation"
             ]
    end

    test "covered dates are absent for the original and present for the cover", ctx do
      {:ok, bea_events} = EffectiveSchedule.calendar_events(ctx.bea.resident_id, :legacy)
      {:ok, cal_events} = EffectiveSchedule.calendar_events(ctx.cal.resident_id, :legacy)

      refute Enum.any?(bea_events, &(&1.dtstart in ["20260715T060000", "20260716T060000"]))

      assert %{
               uid: "seg-elective-2026-07-15-2026-07-15@residency-schedule",
               dtstart: "20260715T060000",
               dtend: "20260715T180000",
               summary: "Elective"
             } in cal_events

      refute Enum.any?(
               cal_events,
               &(&1.uid == "seg-strong_obstetrics-2026-07-13-2026-07-15@residency-schedule")
             )

      assert Enum.count(cal_events, &(&1.dtstart == "20260715T060000")) == 1
    end

    test "an unknown person has no events and an unknown version is rejected", ctx do
      assert EffectiveSchedule.calendar_events(-1, :legacy) == {:ok, []}

      assert EffectiveSchedule.calendar_events(ctx.ada.resident_id, :nope) ==
               {:error, :unknown_version}
    end
  end

  defp record(ctx, resident, date) do
    {:ok, records} = EffectiveSchedule.for_schedule(ctx.schedule.id, :legacy)
    Enum.find(records, &(&1.schedule_resident_id == resident.id and &1.date == date))
  end

  defp insert_resident(schedule, name, position_code, year, number) do
    {:ok, resident} =
      Residents.insert_resident(schedule.id, %{
        position_code: position_code,
        residency_year: year,
        schedule_number: number,
        name: name
      })

    resident
  end

  defp insert_blocks(resident, blocks) do
    rotations =
      blocks
      |> Enum.with_index()
      |> Enum.map(fn {{type, first, last}, index} ->
        %{rotation_type: type, start_date: first, end_date: last, slot_index: index}
      end)

    {:ok, _} = Rotations.insert_rotations(resident.id, rotations)
  end

  defp add_activity(resident, date, task) do
    admin = ScheduleFixtures.admin_user()

    batch =
      Repo.insert!(%ImportBatch{
        schedule_id: resident.schedule_id,
        created_by_id: admin.id,
        fingerprint: Ecto.UUID.generate(),
        header_start: date,
        header_end: date
      })

    activity =
      Repo.insert!(%Activity{schedule_resident_id: resident.id, date: date, raw_task: task})

    Repo.insert!(%ActivitySource{
      activity_id: activity.id,
      batch_id: batch.id,
      source_sheet: "Synthetic",
      source_cell: "A#{activity.id}",
      raw_staff: resident.name,
      display_name: resident.name,
      previous_name: resident.name
    })

    activity
  end
end
