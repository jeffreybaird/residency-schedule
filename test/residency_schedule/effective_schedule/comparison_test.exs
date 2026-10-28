defmodule ResidencySchedule.EffectiveSchedule.ComparisonTest do
  use ResidencySchedule.DataCase, async: true

  alias ResidencySchedule.EffectiveSchedule
  alias ResidencySchedule.EffectiveSchedule.Comparison
  alias ResidencySchedule.ScheduleFixtures

  doctest Comparison

  defp record(schedule_resident_id, date, duties \\ []) do
    %{
      person_id: schedule_resident_id * 10,
      schedule_resident_id: schedule_resident_id,
      schedule_id: 1,
      date: date,
      duties: duties,
      off: if(duties == [], do: :blank, else: nil)
    }
  end

  defp duty(code) do
    %{
      kind: :rotation,
      code: code,
      label: code,
      status: :working,
      source_tasks: [],
      timing: %{precision: :date_only, period: nil},
      covered_by_person_id: nil,
      original_person_id: nil,
      source_assignment_date: nil
    }
  end

  defp event(uid, dtstart) do
    %{uid: uid, dtstart: dtstart, dtend: dtstart, summary: "Ambulatory"}
  end

  describe "diff_days/2" do
    test "identical record sets differ nowhere" do
      records = [
        record(1, ~D[2026-07-06], [duty("ambulatory")]),
        record(1, ~D[2026-07-07]),
        record(2, ~D[2026-07-06], [duty("oncology")])
      ]

      assert Comparison.diff_days(records, records) == {3, []}
      assert Comparison.diff_days([], []) == {0, []}
    end

    test "a record that differs on either side is listed with both versions" do
      same = record(1, ~D[2026-07-06], [duty("ambulatory")])
      legacy = record(1, ~D[2026-07-07], [duty("ambulatory")])
      v2 = record(1, ~D[2026-07-07], [duty("elective")])

      assert Comparison.diff_days([same, legacy], [same, v2]) ==
               {1, [%{schedule_resident_id: 1, date: ~D[2026-07-07], legacy: legacy, v2: v2}]}
    end

    test "a day present on only one side is listed with nil for the other" do
      same = record(2, ~D[2026-07-06])
      only_legacy = record(1, ~D[2026-07-06])
      only_v2 = record(3, ~D[2026-07-08])

      assert Comparison.diff_days([only_legacy, same], [same, only_v2]) ==
               {1,
                [
                  %{schedule_resident_id: 1, date: ~D[2026-07-06], legacy: only_legacy, v2: nil},
                  %{schedule_resident_id: 3, date: ~D[2026-07-08], legacy: nil, v2: only_v2}
                ]}
    end

    test "differing days are sorted by resident then chronological date" do
      records = [
        record(2, ~D[2026-01-05]),
        record(2, ~D[2025-12-31]),
        record(1, ~D[2026-07-06])
      ]

      {0, differing} = Comparison.diff_days(records, [])

      assert Enum.map(differing, &{&1.schedule_resident_id, &1.date}) == [
               {1, ~D[2026-07-06]},
               {2, ~D[2025-12-31]},
               {2, ~D[2026-01-05]}
             ]
    end
  end

  describe "diff_events/2" do
    test "identical per-person sets differ nowhere" do
      events = %{
        5 => [event("seg-ambulatory-2026-07-06-2026-07-06@residency-schedule", "20260706T060000")],
        6 => []
      }

      assert Comparison.diff_events(events, events) == []
      assert Comparison.diff_events(%{}, %{}) == []
    end

    test "events on only one side are listed per person with nil for the other" do
      shared = event("seg-ambulatory-2026-07-06-2026-07-06@residency-schedule", "20260706T060000")

      legacy_only =
        event("seg-ambulatory-2026-07-06-2026-07-07@residency-schedule", "20260707T060000")

      v2_only = event("seg-elective-2026-07-06-2026-07-07@residency-schedule", "20260707T060000")
      missing_person = event("seg-vacation-2026-07-08@residency-schedule", "20260708")

      legacy = %{5 => [shared, legacy_only], 6 => [missing_person]}
      v2 = %{5 => [v2_only, shared]}

      assert Comparison.diff_events(legacy, v2) == [
               %{person_id: 5, legacy: legacy_only, v2: nil},
               %{person_id: 5, legacy: nil, v2: v2_only},
               %{person_id: 6, legacy: missing_person, v2: nil}
             ]
    end

    test "a changed summary or end on the same uid counts as one event on each side" do
      before = event("seg-ambulatory-2026-07-06-2026-07-06@residency-schedule", "20260706T060000")
      changed = %{before | summary: "Elective"}

      assert Comparison.diff_events(%{5 => [before]}, %{5 => [changed]}) == [
               %{person_id: 5, legacy: before, v2: nil},
               %{person_id: 5, legacy: nil, v2: changed}
             ]
    end

    test "order of events within a person does not matter" do
      first = event("seg-ambulatory-2026-07-06-2026-07-06@residency-schedule", "20260706T060000")
      second = event("seg-ambulatory-2026-07-06-2026-07-07@residency-schedule", "20260707T060000")
      assert Comparison.diff_events(%{5 => [first, second]}, %{5 => [second, first]}) == []
    end
  end

  describe "run/1" do
    test "reports zero differences and every record identical for a seeded schedule" do
      %{schedule: schedule} = ScheduleFixtures.seed_mini_schedule()
      {:ok, records} = EffectiveSchedule.for_schedule(schedule.id, :legacy)
      assert length(records) == 63

      assert Comparison.run(schedule.id) ==
               {:ok,
                %{
                  schedule_id: schedule.id,
                  identical_days: 63,
                  differing_days: 0,
                  differing_calendar_events: 0,
                  differing_consumer_outputs: 0,
                  detail: %{days: [], calendar_events: []}
                }}
    end

    test "covers overrides and other schedules of the same people without differences" do
      data = ScheduleFixtures.seed_mini_schedule()
      ScheduleFixtures.seed_prior_year_for_clare(data)
      rotation = ScheduleFixtures.rotation_on(data.mary, ~D[2026-07-14])

      {:ok, _} =
        ResidencySchedule.ShiftOverrides.create_override(%{
          rotation_id: rotation.id,
          covering_schedule_resident_id: data.tiff.id,
          override_start_date: ~D[2026-07-15],
          override_end_date: ~D[2026-07-16]
        })

      assert {:ok, summary} = Comparison.run(data.schedule.id)
      assert summary.identical_days == 63
      assert summary.differing_days == 0
      assert summary.differing_calendar_events == 0
      assert summary.detail == %{days: [], calendar_events: []}
    end

    test "an unknown schedule is :not_found" do
      assert Comparison.run(-1) == {:error, :not_found}
    end
  end
end
