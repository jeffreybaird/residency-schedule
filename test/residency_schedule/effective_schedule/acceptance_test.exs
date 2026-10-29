defmodule ResidencySchedule.EffectiveSchedule.AcceptanceTest do
  @moduledoc """
  Acceptance scenarios from the release plan's comparison contract, read-side
  only. Each scenario pins legacy meaning and checks missing-evidence diagnostics;
  the CSV-only scenario still compares at zero differences. Named v2 assertions
  distinguish retained evidence from legacy label inference. The v2 computation must reproduce or have
  classified (plan D4). Deliberately out of scope here: ambiguous people
  (identity mappings and Phase 2 evidence), consumer outputs such as service
  and shift counts, matrices, duty hours and assistant summaries (PR 3), and
  incomplete QGenda exports (only blank roster days are covered).
  """

  use ResidencySchedule.DataCase, async: true
  import Ecto.Query

  alias ResidencySchedule.DetailedSchedules
  alias ResidencySchedule.EffectiveSchedule
  alias ResidencySchedule.EffectiveSchedule.Comparison
  alias ResidencySchedule.EffectiveScheduleFixtures, as: Fixtures
  alias ResidencySchedule.Repo
  alias ResidencySchedule.Residents

  @date_only %{precision: :date_only, period: nil}

  defp legacy_records(schedule_id) do
    {:ok, records} = EffectiveSchedule.for_schedule(schedule_id, :legacy)
    records
  end

  defp record(records, resident, date) do
    Enum.find(records, &(&1.schedule_resident_id == resident.id and &1.date == date))
  end

  defp events(resident) do
    {:ok, events} = EffectiveSchedule.calendar_events(resident.resident_id, :legacy)
    events
  end

  defp assert_comparison_contract(schedule_id) do
    records = legacy_records(schedule_id)
    assert records != []
    assert {:ok, summary} = Comparison.run(schedule_id)

    sources =
      Repo.all(
        from s in ResidencySchedule.DetailedSchedules.ActivitySource,
          join: a in assoc(s, :activity),
          join: m in assoc(a, :schedule_resident),
          where: m.schedule_id == ^schedule_id,
          order_by: [m.id, a.date, a.id, s.id],
          select: {a, s.id}
      )

    expected =
      for {activity, source_id} <- sources,
          reason <- [:missing_classification, :missing_identity, :missing_timing],
          do: %{
            reason: reason,
            activity_id: activity.id,
            activity_source_id: source_id,
            schedule_resident_id: activity.schedule_resident_id,
            date: activity.date
          }

    assert summary.unresolved_evidence == length(expected)
    assert summary.detail.evidence == expected
    assert EffectiveSchedule.evidence_diagnostics(schedule_id, :v2) == {:ok, expected}

    if sources == [] do
      assert summary.identical_days == length(records)
      assert summary.differing_days == 0
      assert summary.differing_calendar_events == 0
      assert summary.detail == %{days: [], calendar_events: [], evidence: []}
    end

    records
  end

  defp v2_record(ctx, resident, date) do
    {:ok, records} = EffectiveSchedule.for_schedule(ctx.schedule.id, :v2)
    record(records, resident, date)
  end

  describe "April 5–18 vacation from roster weekdays and imported weekends" do
    setup do
      ctx = Fixtures.april_vacation()
      Map.put(ctx, :records, assert_comparison_contract(ctx.schedule.id))
    end

    test "v2 retains roster vacation but cannot infer weekend vacation without classifications",
         ctx do
      for date <- ctx.weekdays, do: assert(v2_record(ctx, ctx.ada, date).off == :vacation)

      for date <- ctx.weekends do
        assert %{off: nil, duties: [%{code: "qgenda_assignment", label: "Vacation"}]} =
                 v2_record(ctx, ctx.ada, date)
      end
    end

    test "every day of the vacation is one vacation duty that is off", ctx do
      for date <- ctx.vacation_range do
        assert %{duties: [duty], off: :vacation} = record(ctx.records, ctx.ada, date)
        assert duty.code == "vacation"
        assert duty.label == "Vacation"
        assert duty.status == :off
        assert duty.timing == @date_only
        assert duty.covered_by_person_id == nil
        assert duty.original_person_id == nil
      end
    end

    test "weekdays come from the roster and weekends from imported tasks", ctx do
      for date <- ctx.weekdays do
        assert [%{kind: :rotation, source_tasks: [], source_assignment_date: nil}] =
                 record(ctx.records, ctx.ada, date).duties
      end

      for date <- ctx.weekends do
        assert [%{kind: :gap_fill, source_tasks: ["Vacation"], source_assignment_date: ^date}] =
                 record(ctx.records, ctx.ada, date).duties
      end
    end

    test "the dated notes stay attached to the weekend activity sources", ctx do
      for date <- ctx.weekends do
        assert [activity] = DetailedSchedules.list_for_resident(ctx.ada.id, date)
        assert activity.raw_task == "Vacation"

        assert activity.notes == [
                 "#{date.month}/#{date.day}/#{date.year} vacation approved by chief"
               ]
      end
    end

    test "the days around the vacation and the coworker's whole range are working", ctx do
      assert [%{kind: :rotation, code: "ambulatory", status: :working}] =
               record(ctx.records, ctx.ada, ~D[2027-04-04]).duties

      assert [%{kind: :rotation, code: "oncology", status: :working}] =
               record(ctx.records, ctx.ada, ~D[2027-04-19]).duties

      bea_days = Enum.filter(ctx.records, &(&1.schedule_resident_id == ctx.bea.id))
      assert length(bea_days) == 28

      assert Enum.all?(bea_days, fn day ->
               match?(
                 %{duties: [%{kind: :rotation, code: "oncology", status: :working}], off: nil},
                 day
               )
             end)
    end

    test "the calendar identity is one all-day event per roster slot and per weekend day", ctx do
      assert ctx.ada |> events() |> Enum.filter(&(&1.summary == "Vacation")) == [
               %{
                 uid: "seg-vacation-2027-04-05@residency-schedule",
                 dtstart: "20270405",
                 dtend: "20270410",
                 summary: "Vacation"
               },
               %{
                 uid: "seg-vacation-2027-04-10@residency-schedule",
                 dtstart: "20270410",
                 dtend: "20270411",
                 summary: "Vacation"
               },
               %{
                 uid: "seg-vacation-2027-04-11@residency-schedule",
                 dtstart: "20270411",
                 dtend: "20270412",
                 summary: "Vacation"
               },
               %{
                 uid: "seg-vacation-2027-04-12@residency-schedule",
                 dtstart: "20270412",
                 dtend: "20270417",
                 summary: "Vacation"
               },
               %{
                 uid: "seg-vacation-2027-04-17@residency-schedule",
                 dtstart: "20270417",
                 dtend: "20270418",
                 summary: "Vacation"
               },
               %{
                 uid: "seg-vacation-2027-04-18@residency-schedule",
                 dtstart: "20270418",
                 dtend: "20270419",
                 summary: "Vacation"
               }
             ]
    end
  end

  describe "a rotation and a clinic on the same day" do
    setup do
      ctx = Fixtures.rotation_and_clinic_same_day()
      Map.put(ctx, :records, assert_comparison_contract(ctx.schedule.id))
    end

    test "v2 exposes the independent clinic beside the unchanged base rotation", ctx do
      assert [activity, rotation] = v2_record(ctx, ctx.ada, ctx.clinic_date).duties
      assert activity.kind == :dated_activity
      assert activity.code == "qgenda_assignment"
      assert activity.label == ctx.clinic_task
      assert activity.timing == @date_only
      assert rotation.code == "strong_obstetrics"
    end

    test "legacy shows the rotation only; the clinic activity is not a duty", ctx do
      assert [activity] = DetailedSchedules.list_for_resident(ctx.ada.id, ctx.clinic_date)
      assert activity.raw_task == ctx.clinic_task

      assert %{duties: [duty], off: nil} = record(ctx.records, ctx.ada, ctx.clinic_date)
      assert duty.kind == :rotation
      assert duty.code == "strong_obstetrics"
      assert duty.status == :working
      assert duty.source_tasks == []
      assert duty.source_assignment_date == nil
    end

    test "the clinic day's calendar event is the rotation's own timed event", ctx do
      assert Enum.find(events(ctx.ada), &(&1.dtstart == "20270407T060000")) == %{
               uid: "seg-strong_obstetrics-2027-04-05-2027-04-07@residency-schedule",
               dtstart: "20270407T060000",
               dtend: "20270407T180000",
               summary: "Obstetrics – Strong"
             }

      refute Enum.any?(events(ctx.ada), &String.contains?(&1.summary, "Clinic"))
    end
  end

  describe "imported gap filling and approved coverage precedence" do
    setup do
      ctx = Fixtures.gap_fill_and_coverage()
      Map.put(ctx, :records, assert_comparison_contract(ctx.schedule.id))
    end

    test "v2 keeps coverage but cannot infer an unclassified Ultrasound gap", ctx do
      for date <- ctx.coverage_dates do
        assert [%{kind: :coverage, code: "strong_obstetrics"}] =
                 v2_record(ctx, ctx.cal, date).duties
      end

      assert [%{code: "qgenda_assignment", label: "Ultrasound"}] =
               v2_record(ctx, ctx.ada, ctx.gap_fill_date).duties
    end

    test "a resolved task on a blank day is a gap fill of its resolved type", ctx do
      assert %{duties: [duty], off: nil} = record(ctx.records, ctx.ada, ctx.gap_fill_date)
      assert duty.kind == :gap_fill
      assert duty.code == "ultrasound"
      assert duty.label == "Ultrasound"
      assert duty.status == :working
      assert duty.source_tasks == ["Ultrasound"]
      assert duty.source_assignment_date == ctx.gap_fill_date

      assert record(ctx.records, ctx.ada, ctx.blank_date) |> Map.take([:duties, :off]) == %{
               duties: [],
               off: :blank
             }
    end

    test "the covered resident's days are covered and the cover's days are coverage duties",
         ctx do
      for date <- ctx.coverage_dates do
        assert %{duties: [covered], off: nil} = record(ctx.records, ctx.bea, date)
        assert covered.kind == :rotation
        assert covered.code == "strong_obstetrics"
        assert covered.status == :covered
        assert covered.covered_by_person_id == ctx.cal.resident_id

        assert %{duties: [coverage], off: nil} = record(ctx.records, ctx.cal, date)
        assert coverage.kind == :coverage
        assert coverage.code == "strong_obstetrics"
        assert coverage.status == :working
        assert coverage.original_person_id == ctx.bea.resident_id
        assert coverage.source_tasks == []
      end
    end

    test "coverage wins over a gap fill dated inside the covered range", ctx do
      assert [activity] = DetailedSchedules.list_for_resident(ctx.cal.id, ctx.covered_gap_date)
      assert activity.raw_task == "Ultrasound"

      assert [%{kind: :coverage, code: "strong_obstetrics"}] =
               record(ctx.records, ctx.cal, ctx.covered_gap_date).duties

      assert [%{kind: :gap_fill, code: "ultrasound", source_tasks: ["Ultrasound"]}] =
               record(ctx.records, ctx.cal, ctx.uncovered_gap_date).duties
    end

    test "the cover's calendar carries the coverage days and the covered resident's omits them",
         ctx do
      cal_uids = ctx.cal |> events() |> Enum.map(& &1.uid)

      assert "seg-strong_obstetrics-2027-04-14-2027-04-14@residency-schedule" in cal_uids
      assert "seg-strong_obstetrics-2027-04-14-2027-04-15@residency-schedule" in cal_uids
      assert "seg-ultrasound-2027-04-16-2027-04-16@residency-schedule" in cal_uids
      refute Enum.any?(cal_uids, &String.contains?(&1, "2027-04-14-2027-04-16"))

      bea_starts = ctx.bea |> events() |> Enum.map(& &1.dtstart)
      refute "20270414T060000" in bea_starts
      refute "20270415T060000" in bea_starts
      assert "20270413T060000" in bea_starts
      assert "20270416T060000" in bea_starts
    end
  end

  describe "Strong and Highland overnight boundaries and the Friday correction" do
    setup do
      ctx = Fixtures.night_boundaries_and_friday()
      Map.put(ctx, :records, assert_comparison_contract(ctx.schedule.id))
    end

    test "v2 preserves base duties when literal night tasks lack classification evidence", ctx do
      cal = v2_record(ctx, ctx.cal, ctx.corrected_friday)
      assert Enum.any?(cal.duties, &(&1.code == "ambulatory" and &1.kind == :rotation))
      refute Enum.any?(cal.duties, &(&1.code == "strong_weekend_nights"))

      assert [%{code: "qgenda_assignment"}] =
               v2_record(ctx, ctx.dee, ctx.highland_saturday).duties
    end

    test "a canonical Strong night block shifts to the evening before with its source date",
         ctx do
      for date <- Date.range(~D[2026-11-01], ~D[2026-11-05]) do
        assert [duty] = record(ctx.records, ctx.bea, date).duties
        assert duty.kind == :rotation
        assert duty.code == "night_float"
        assert duty.status == :working
        assert duty.source_assignment_date == ctx.shifted_sunday
      end

      assert record(ctx.records, ctx.ada, ctx.shifted_sunday).off == :blank
    end

    test "the explicit Friday night is preserved from the literal activity", ctx do
      assert [duty] = record(ctx.records, ctx.bea, ctx.explicit_friday).duties
      assert duty.code == "night_float"
      assert duty.source_assignment_date == ctx.explicit_friday

      assert [%{code: "post_call", source_assignment_date: nil}] =
               record(ctx.records, ctx.bea, ~D[2026-11-07]).duties

      assert [%{code: "strong_weekend_nights", source_assignment_date: ~D[2026-11-06]}] =
               record(ctx.records, ctx.ada, ctx.explicit_friday).duties
    end

    test "the Friday correction turns an ambulatory Friday with a contact night into weekend nights",
         ctx do
      assert [duty] = record(ctx.records, ctx.cal, ctx.corrected_friday).duties
      assert duty.kind == :rotation
      assert duty.code == "strong_weekend_nights"
      assert duty.source_assignment_date == ctx.corrected_friday
      assert duty.source_tasks == []

      assert [%{code: "ambulatory", source_assignment_date: nil}] =
               record(ctx.records, ctx.cal, ~D[2026-11-12]).duties

      assert [%{code: "post_call"}] = record(ctx.records, ctx.bea, ctx.corrected_friday).duties
    end

    test "Highland night float keeps its dates and removes the overlapping post call", ctx do
      assert [%{code: "post_call"}] = record(ctx.records, ctx.dee, ~D[2026-11-07]).duties

      for date <- Date.range(~D[2026-11-08], ~D[2026-11-13]) do
        assert [duty] = record(ctx.records, ctx.dee, date).duties
        assert duty.kind == :rotation
        assert duty.code == "highland_night_float"
        assert duty.source_assignment_date == nil
        assert duty.source_tasks == []
      end
    end

    test "a Saturday Highland night without a rotation is a weekend-night gap fill; Sunday is unresolved",
         ctx do
      assert [saturday] = record(ctx.records, ctx.dee, ctx.highland_saturday).duties
      assert saturday.kind == :gap_fill
      assert saturday.code == "highland_weekend_nights"
      assert saturday.source_tasks == ["HH Nights 3rd Call"]

      assert [sunday] = record(ctx.records, ctx.dee, ctx.highland_sunday).duties
      assert sunday.kind == :gap_fill
      assert sunday.code == "qgenda_assignment"
      assert sunday.source_tasks == ["HH Nights 3rd Call"]
    end

    test "calendar identities carry the shifted start date and evening-first times", ctx do
      bea_events = events(ctx.bea)

      assert %{
               uid: "seg-night_float-2026-11-01-2026-11-01@residency-schedule",
               dtstart: "20261101T180000",
               dtend: "20261102T060000",
               summary: "Night Float – Strong"
             } in bea_events

      assert %{
               uid: "seg-night_float-2026-11-06-2026-11-06@residency-schedule",
               dtstart: "20261106T180000",
               dtend: "20261107T060000",
               summary: "Night Float – Strong"
             } in bea_events

      assert %{
               uid: "seg-post_call-2026-11-07@residency-schedule",
               dtstart: "20261107",
               dtend: "20261108",
               summary: "Post Call"
             } in bea_events

      assert %{
               uid: "seg-strong_weekend_nights-2026-11-13-2026-11-13@residency-schedule",
               dtstart: "20261113T180000",
               dtend: "20261114T060000",
               summary: "Weekend Nights – Strong"
             } in events(ctx.cal)

      dee_events = events(ctx.dee)

      assert %{
               uid: "seg-highland_night_float-2026-11-08-2026-11-08@residency-schedule",
               dtstart: "20261107T180000",
               dtend: "20261108T060000",
               summary: "Night Float – Highland"
             } in dee_events

      # Keep the one-day post-call event even though the unsourced night starts
      # that evening; trimming would erase the event from calendar clients.
      assert %{
               uid: "seg-post_call-2026-11-07@residency-schedule",
               dtstart: "20261107",
               dtend: "20261108",
               summary: "Post Call"
             } in dee_events
    end
  end

  describe "blank input, OFF, unknown tasks and changed labels" do
    setup do
      ctx = Fixtures.blank_off_unknown_and_changed_labels()
      Map.put(ctx, :records, assert_comparison_contract(ctx.schedule.id))
    end

    test "v2 retains neutral OFF and blank dates without inventing evidence", ctx do
      assert %{off: nil, duties: [%{code: "qgenda_assignment", label: "OFF"}]} =
               v2_record(ctx, ctx.ada, ctx.off_date)

      for date <- ctx.blank_dates, do: assert(v2_record(ctx, ctx.ada, date).off == :blank)
    end

    test "days with no rotation and no task are blank", ctx do
      for date <- ctx.blank_dates do
        assert %{duties: [], off: :blank} = record(ctx.records, ctx.ada, date)
      end

      assert [%{code: "ambulatory"}] = record(ctx.records, ctx.bea, hd(ctx.blank_dates)).duties
    end

    test "legacy shows an OFF task as an unresolved working gap fill with its raw label", ctx do
      assert %{duties: [duty], off: nil} = record(ctx.records, ctx.ada, ctx.off_date)
      assert duty.kind == :gap_fill
      assert duty.code == "qgenda_assignment"
      assert duty.label == "OFF"
      assert duty.status == :working
      assert duty.source_tasks == ["OFF"]
    end

    test "an unknown task and its changed label stay visible with their raw labels", ctx do
      assert %{duties: [unknown]} = record(ctx.records, ctx.ada, ctx.unknown_date)
      assert unknown.code == "qgenda_assignment"
      assert unknown.label == ctx.unknown_task
      assert unknown.source_tasks == [ctx.unknown_task]

      assert %{duties: [changed]} = record(ctx.records, ctx.ada, ctx.changed_label_date)
      assert changed.code == "qgenda_assignment"
      assert changed.label == ctx.changed_label_task
      assert changed.source_tasks == [ctx.changed_label_task]
    end

    test "each unresolved task is one all-day calendar event named by its label", ctx do
      assert ctx.ada |> events() |> Enum.filter(&String.starts_with?(&1.uid, "seg-qgenda")) == [
               %{
                 uid: "seg-qgenda_assignment-2027-04-13@residency-schedule",
                 dtstart: "20270413",
                 dtend: "20270414",
                 summary: "OFF"
               },
               %{
                 uid: "seg-qgenda_assignment-2027-04-14@residency-schedule",
                 dtstart: "20270414",
                 dtend: "20270415",
                 summary: "Mystery Clinic PM"
               },
               %{
                 uid: "seg-qgenda_assignment-2027-04-15@residency-schedule",
                 dtstart: "20270415",
                 dtend: "20270416",
                 summary: "Mystery Clinic - PM"
               }
             ]
    end
  end

  describe "identical reimports and a correction after earlier imports" do
    setup do
      ctx = Fixtures.reimport_and_correction(&snapshot/1)
      Map.put(ctx, :records, assert_comparison_contract(ctx.schedule_id))
    end

    defp snapshot(schedule_id) do
      briar =
        schedule_id
        |> Residents.list_residents_for_schedule()
        |> Enum.find(&(&1.position_code == "R4-1"))

      %{
        days:
          schedule_id
          |> legacy_records()
          |> Map.new(&{{&1.person_id, &1.date}, Map.drop(&1, [:schedule_resident_id])}),
        briar_events: events(briar)
      }
    end

    test "every import lands in the same schedule with the same people, and whole-year replacement regenerates schedule resident ids",
         ctx do
      assert [id, id, id] = ctx.schedule_ids

      for key <- [:second, :third] do
        assert Map.keys(ctx.ids[key]) == Map.keys(ctx.ids.first)

        for {position, %{person_id: person_id}} <- ctx.ids.first do
          assert ctx.ids[key][position].person_id == person_id
        end
      end

      # Legacy whole-year replacement deletes and reinserts schedule residents,
      # so only the person identity is stable across an identical reimport.
      for {position, %{schedule_resident_id: first_id}} <- ctx.ids.first do
        refute ctx.ids.second[position].schedule_resident_id == first_id
      end
    end

    test "an identical reimport leaves records and calendar identities unchanged and a correction changes only the corrected dates",
         ctx do
      assert map_size(ctx.snapshots.first.days) == length(ctx.records)
      assert ctx.snapshots.second.days == ctx.snapshots.first.days

      briar_person = ctx.ids.third[ctx.corrected_position].person_id
      before = ctx.snapshots.second.days
      after_correction = ctx.snapshots.third.days

      changed =
        before
        |> Enum.reject(fn {key, day} -> after_correction[key] == day end)
        |> Enum.map(fn {key, _day} -> key end)
        |> Enum.sort()

      assert changed == Enum.map(ctx.corrected_dates, &{briar_person, &1})

      for date <- ctx.corrected_dates do
        assert [%{code: original}] = before[{briar_person, date}].duties
        assert original == ctx.original_type
        assert [%{code: corrected}] = after_correction[{briar_person, date}].duties
        assert corrected == ctx.corrected_type
      end

      assert ctx.snapshots.first.briar_events != []
      assert ctx.snapshots.second.briar_events == ctx.snapshots.first.briar_events

      before_uids = MapSet.new(ctx.snapshots.second.briar_events, & &1.uid)
      after_uids = MapSet.new(ctx.snapshots.third.briar_events, & &1.uid)

      assert "seg-oncology-2023-07-03-2023-07-03@residency-schedule" in before_uids
      refute "seg-oncology-2023-07-03-2023-07-03@residency-schedule" in after_uids
      assert "seg-strong_gynecology-2023-07-03-2023-07-07@residency-schedule" in after_uids
      assert "seg-oncology-2023-07-10-2023-07-10@residency-schedule" in after_uids
    end
  end
end
