defmodule ResidencySchedule.EffectiveSchedule.NormalizeTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.EffectiveSchedule.Normalize

  doctest Normalize

  @membership %{person_id: 1, schedule_resident_id: 2, schedule_id: 3}
  @date_only %{precision: :date_only, period: nil}

  defp own(type, start_date, end_date, overrides \\ %{}) do
    Map.merge(
      %{
        rotation_type: type,
        start_date: start_date,
        end_date: end_date,
        slot_index: 0,
        is_coverage: false,
        covered_by: nil,
        original_resident: nil,
        source_assignment_date: nil,
        source_tasks: []
      },
      overrides
    )
  end

  defp gap(type, date, tasks) do
    own(type, date, date, %{
      slot_index: -1,
      source_assignment_date: date,
      source_tasks: tasks
    })
  end

  defp coverage(type, start_date, end_date, original_person_id) do
    %{
      rotation_type: type,
      start_date: start_date,
      end_date: end_date,
      slot_index: -1,
      is_coverage: true,
      covered_by: nil,
      original_resident: %{id: 40, resident_id: original_person_id}
    }
  end

  defp duty(overrides) do
    Map.merge(
      %{
        kind: :rotation,
        code: "ambulatory",
        label: "Ambulatory",
        status: :working,
        source_tasks: [],
        timing: @date_only,
        covered_by_person_id: nil,
        original_person_id: nil,
        source_assignment_date: nil
      },
      overrides
    )
  end

  describe "duty_from_segment/1" do
    test "maps a plain own rotation segment to a working rotation duty" do
      assert Normalize.duty_from_segment(own("strong_obstetrics", ~D[2026-07-06], ~D[2026-07-12])) ==
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
    end

    test "a covered own segment is :covered and names the covering person" do
      segment =
        own("elective", ~D[2026-07-15], ~D[2026-07-16], %{
          covered_by: %{id: 30, resident_id: 77}
        })

      duty = Normalize.duty_from_segment(segment)
      assert duty.kind == :rotation
      assert duty.status == :covered
      assert duty.covered_by_person_id == 77
      assert duty.original_person_id == nil
    end

    test "a coverage segment is :coverage and names the original person" do
      duty = Normalize.duty_from_segment(coverage("elective", ~D[2026-07-15], ~D[2026-07-16], 88))
      assert duty.kind == :coverage
      assert duty.code == "elective"
      assert duty.label == "Elective"
      assert duty.status == :working
      assert duty.original_person_id == 88
      assert duty.covered_by_person_id == nil
      assert duty.source_tasks == []
      assert duty.source_assignment_date == nil
      assert duty.timing == @date_only
    end

    test "coverage wins over the gap-fill slot index" do
      duty =
        Normalize.duty_from_segment(coverage("ambulatory", ~D[2026-07-01], ~D[2026-07-01], 5))

      assert duty.kind == :coverage
    end

    test "a projected gap row is :gap_fill with its literal tasks and source date" do
      duty =
        Normalize.duty_from_segment(
          gap("qgenda_assignment", ~D[2026-07-21], ["Mystery Clinic PM", "Another Task"])
        )

      assert duty == %{
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
    end

    test "a projected night row with a source date but a canonical slot stays :rotation" do
      segment =
        own("strong_weekend_nights", ~D[2026-11-06], ~D[2026-11-07], %{
          slot_index: 1,
          source_assignment_date: ~D[2026-11-06],
          source_tasks: ["SMH Obstetrics Resident 1st Contact Night"]
        })

      duty = Normalize.duty_from_segment(segment)
      assert duty.kind == :rotation
      assert duty.source_assignment_date == ~D[2026-11-06]
      assert duty.source_tasks == ["SMH Obstetrics Resident 1st Contact Night"]
      assert duty.label == "SMH Obstetrics Resident 1st Contact Night"
    end

    test "vacation and leave of absence are :off" do
      assert Normalize.duty_from_segment(own("vacation", ~D[2026-07-20], ~D[2026-07-26])).status ==
               :off

      leave = Normalize.duty_from_segment(own("leave_of_absence", ~D[2026-07-20], ~D[2026-07-26]))
      assert leave.status == :off
      assert leave.label == "Leave of Absence"
    end

    test "a covered vacation is :covered rather than :off" do
      segment =
        own("vacation", ~D[2026-07-20], ~D[2026-07-26], %{covered_by: %{id: 1, resident_id: 9}})

      assert Normalize.duty_from_segment(segment).status == :covered
    end

    test "timing is always date-only in the legacy mapping" do
      for segment <- [
            own("night_float", ~D[2026-07-20], ~D[2026-07-26]),
            gap("vacation", ~D[2026-07-05], ["Vacation"]),
            coverage("night_float", ~D[2026-07-20], ~D[2026-07-21], 3)
          ] do
        assert Normalize.duty_from_segment(segment).timing == @date_only
      end
    end
  end

  describe "sort_duties/1" do
    test "orders by kind, then code, status, source date, tasks and people" do
      a = duty(%{kind: :coverage, code: "night_float", label: "Night Float – Strong"})

      b =
        duty(%{
          kind: :gap_fill,
          code: "qgenda_assignment",
          source_assignment_date: ~D[2026-07-01]
        })

      c = duty(%{kind: :rotation, code: "ambulatory", status: :covered, covered_by_person_id: 4})
      d = duty(%{kind: :rotation, code: "ambulatory", status: :working})
      e = duty(%{kind: :rotation, code: "vacation", status: :off})

      assert Normalize.sort_duties([e, d, c, b, a]) == [a, b, c, d, e]
      assert Normalize.sort_duties([a, b, c, d, e]) == [a, b, c, d, e]
    end

    test "a nil source date sorts before any date and dates compare chronologically" do
      none = duty(%{kind: :gap_fill, code: "qgenda_assignment", source_assignment_date: nil})

      december =
        duty(%{
          kind: :gap_fill,
          code: "qgenda_assignment",
          source_assignment_date: ~D[2025-12-31]
        })

      january =
        duty(%{
          kind: :gap_fill,
          code: "qgenda_assignment",
          source_assignment_date: ~D[2026-01-05]
        })

      assert Normalize.sort_duties([january, december, none]) == [none, december, january]
    end

    test "equal prefixes fall through to tasks, covering person and original person" do
      base = %{kind: :gap_fill, code: "qgenda_assignment", source_assignment_date: ~D[2026-07-21]}
      tasks_a = duty(Map.put(base, :source_tasks, ["Alpha"]))
      tasks_b = duty(Map.put(base, :source_tasks, ["Beta"]))
      covered_by_2 = duty(%{kind: :coverage, code: "elective", covered_by_person_id: 2})
      covered_by_3 = duty(%{kind: :coverage, code: "elective", covered_by_person_id: 3})
      original_5 = duty(%{kind: :coverage, code: "elective", original_person_id: 5})
      original_6 = duty(%{kind: :coverage, code: "elective", original_person_id: 6})

      assert Normalize.sort_duties([tasks_b, tasks_a]) == [tasks_a, tasks_b]
      assert Normalize.sort_duties([covered_by_3, covered_by_2]) == [covered_by_2, covered_by_3]
      assert Normalize.sort_duties([original_6, original_5]) == [original_5, original_6]
    end

    test "label and complete timing break equal-prefix ties independently of insertion order" do
      am = duty(%{label: "Alpha", timing: %{precision: :period, period: "AM"}})
      pm = duty(%{label: "Alpha", timing: %{precision: :period, period: "PM"}})
      later_label = duty(%{label: "Beta", timing: %{precision: :period, period: "AM"}})

      exact =
        duty(%{
          label: "Alpha",
          timing: %{
            precision: :exact,
            period: nil,
            starts_at: ~U[2026-11-03 12:00:00Z],
            ends_at: ~U[2026-11-03 13:00:00Z],
            time_zone: "Etc/UTC"
          }
        })

      later_exact = put_in(exact.timing.ends_at, ~U[2026-11-03 14:00:00Z])
      duties = [pm, later_label, exact, am, later_exact]
      sorted = Normalize.sort_duties(duties)
      assert length(sorted) == 5
      assert MapSet.new(sorted) == MapSet.new(duties)

      for permutation <- [
            Enum.reverse(duties),
            [am, exact, later_label, later_exact, pm],
            [later_exact, pm, am, exact, later_label]
          ] do
        assert Normalize.sort_duties(permutation) == sorted
      end

      assert Normalize.sort_duties([pm, am]) == [am, pm]
      assert Normalize.sort_duties([later_label, am]) == [am, later_label]
      assert Normalize.sort_duties([later_exact, exact]) == [exact, later_exact]
    end

    test "an empty list stays empty" do
      assert Normalize.sort_duties([]) == []
    end
  end

  describe "off_state/1" do
    test "no duties is :blank" do
      assert Normalize.off_state([]) == :blank
    end

    test "working duties only is nil" do
      assert Normalize.off_state([duty(%{})]) == nil
    end

    test "a vacation duty is :vacation" do
      assert Normalize.off_state([duty(%{code: "vacation", status: :off})]) == :vacation
    end

    test "a leave of absence duty is :leave" do
      assert Normalize.off_state([duty(%{code: "leave_of_absence", status: :off})]) == :leave
    end

    test "vacation wins when vacation and leave share a day" do
      duties = [
        duty(%{code: "leave_of_absence", status: :off}),
        duty(%{code: "vacation", status: :off})
      ]

      assert Normalize.off_state(duties) == :vacation
    end

    test "a covered vacation still reports :vacation" do
      assert Normalize.off_state([
               duty(%{code: "vacation", status: :covered, covered_by_person_id: 9})
             ]) == :vacation
    end
  end

  describe "daily_records/3" do
    test "expands one segment to one record per date and fills blank days" do
      segments = [own("ambulatory", ~D[2026-07-07], ~D[2026-07-08])]
      range = Date.range(~D[2026-07-06], ~D[2026-07-09])

      records = Normalize.daily_records(segments, @membership, range)
      assert Enum.map(records, & &1.date) == Enum.to_list(range)

      assert Enum.map(records, &{&1.person_id, &1.schedule_resident_id, &1.schedule_id}) ==
               List.duplicate({1, 2, 3}, 4)

      assert Enum.at(records, 0) == %{
               person_id: 1,
               schedule_resident_id: 2,
               schedule_id: 3,
               date: ~D[2026-07-06],
               duties: [],
               off: :blank
             }

      assert Enum.at(records, 1) == %{
               person_id: 1,
               schedule_resident_id: 2,
               schedule_id: 3,
               date: ~D[2026-07-07],
               duties: [duty(%{})],
               off: nil
             }

      assert Enum.at(records, 2).duties == [duty(%{})]
      assert Enum.at(records, 3) == %{Enum.at(records, 0) | date: ~D[2026-07-09]}
    end

    test "dates outside the range are dropped and no segments yields only blank days" do
      segments = [own("ambulatory", ~D[2026-07-01], ~D[2026-07-31])]
      range = Date.range(~D[2026-07-10], ~D[2026-07-11])

      assert Enum.map(Normalize.daily_records(segments, @membership, range), & &1.date) ==
               [~D[2026-07-10], ~D[2026-07-11]]

      assert Normalize.daily_records([], @membership, range) == [
               %{
                 person_id: 1,
                 schedule_resident_id: 2,
                 schedule_id: 3,
                 date: ~D[2026-07-10],
                 duties: [],
                 off: :blank
               },
               %{
                 person_id: 1,
                 schedule_resident_id: 2,
                 schedule_id: 3,
                 date: ~D[2026-07-11],
                 duties: [],
                 off: :blank
               }
             ]
    end

    test "two segments on one day produce two sorted duties" do
      segments = [
        own("ambulatory", ~D[2026-07-06], ~D[2026-07-06]),
        coverage("night_float", ~D[2026-07-06], ~D[2026-07-06], 9)
      ]

      [record] =
        Normalize.daily_records(segments, @membership, Date.range(~D[2026-07-06], ~D[2026-07-06]))

      assert Enum.map(record.duties, & &1.kind) == [:coverage, :rotation]

      assert record.duties ==
               Normalize.sort_duties(Enum.map(segments, &Normalize.duty_from_segment/1))

      assert record.off == nil
    end

    test "off state follows the day's duties" do
      segments = [
        own("vacation", ~D[2026-07-06], ~D[2026-07-06]),
        own("leave_of_absence", ~D[2026-07-07], ~D[2026-07-07]),
        gap("vacation", ~D[2026-07-08], ["Vacation"]),
        own("vacation", ~D[2026-07-09], ~D[2026-07-09]),
        own("leave_of_absence", ~D[2026-07-09], ~D[2026-07-09])
      ]

      range = Date.range(~D[2026-07-06], ~D[2026-07-10])
      records = Normalize.daily_records(segments, @membership, range)
      assert Enum.map(records, & &1.off) == [:vacation, :leave, :vacation, :vacation, :blank]
      assert Enum.map(records, &length(&1.duties)) == [1, 1, 1, 2, 0]
      assert hd(Enum.at(records, 2).duties).kind == :gap_fill
    end

    test "covered and coverage segments carry the people involved" do
      segments = [
        own("elective", ~D[2026-07-15], ~D[2026-07-16], %{covered_by: %{id: 30, resident_id: 77}}),
        coverage("night_float", ~D[2026-07-16], ~D[2026-07-16], 88)
      ]

      range = Date.range(~D[2026-07-15], ~D[2026-07-16])
      [first, second] = Normalize.daily_records(segments, @membership, range)

      assert [%{status: :covered, covered_by_person_id: 77}] = first.duties
      assert first.off == nil

      assert [
               %{kind: :coverage, original_person_id: 88, status: :working},
               %{kind: :rotation, status: :covered, covered_by_person_id: 77}
             ] = second.duties
    end
  end
end
