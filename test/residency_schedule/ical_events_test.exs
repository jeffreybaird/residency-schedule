defmodule ResidencySchedule.IcalEventsTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Ical

  doctest Ical

  @name "Synthetic Resident"

  defp segment(type, start_date, end_date, overrides \\ %{}) do
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

  describe "events_from_segments/2" do
    test "an all-day segment is one event with an exclusive end date" do
      assert Ical.events_from_segments(
               [segment("vacation", ~D[2026-07-20], ~D[2026-07-26])],
               @name
             ) ==
               [
                 %{
                   uid: "seg-vacation-2026-07-20@residency-schedule",
                   dtstart: "20260720",
                   dtend: "20260727",
                   summary: "Vacation"
                 }
               ]
    end

    test "a timed segment is one event per day from 6am to 6pm" do
      events =
        Ical.events_from_segments([segment("ambulatory", ~D[2026-07-13], ~D[2026-07-15])], @name)

      assert events == [
               %{
                 uid: "seg-ambulatory-2026-07-13-2026-07-13@residency-schedule",
                 dtstart: "20260713T060000",
                 dtend: "20260713T180000",
                 summary: "Ambulatory"
               },
               %{
                 uid: "seg-ambulatory-2026-07-13-2026-07-14@residency-schedule",
                 dtstart: "20260714T060000",
                 dtend: "20260714T180000",
                 summary: "Ambulatory"
               },
               %{
                 uid: "seg-ambulatory-2026-07-13-2026-07-15@residency-schedule",
                 dtstart: "20260715T060000",
                 dtend: "20260715T180000",
                 summary: "Ambulatory"
               }
             ]
    end

    test "a night shift starts at 6pm the evening before each listed date" do
      assert Ical.events_from_segments(
               [segment("night_float", ~D[2026-07-20], ~D[2026-07-21])],
               @name
             ) ==
               [
                 %{
                   uid: "seg-night_float-2026-07-20-2026-07-20@residency-schedule",
                   dtstart: "20260719T180000",
                   dtend: "20260720T060000",
                   summary: "Night Float – Strong"
                 },
                 %{
                   uid: "seg-night_float-2026-07-20-2026-07-21@residency-schedule",
                   dtstart: "20260720T180000",
                   dtend: "20260721T060000",
                   summary: "Night Float – Strong"
                 }
               ]
    end

    test "an imported night with a source date runs from 6pm on the listed date" do
      imported =
        segment("strong_weekend_nights", ~D[2026-11-06], ~D[2026-11-06], %{
          source_assignment_date: ~D[2026-11-06],
          source_tasks: ["SMH Obstetrics Resident 1st Contact Night"]
        })

      assert Ical.events_from_segments([imported], @name) == [
               %{
                 uid: "seg-strong_weekend_nights-2026-11-06-2026-11-06@residency-schedule",
                 dtstart: "20261106T180000",
                 dtend: "20261107T060000",
                 summary: "SMH Obstetrics Resident 1st Contact Night"
               }
             ]
    end

    test "the day before a night shift is trimmed from the previous segment" do
      segments = [
        segment("ambulatory", ~D[2026-07-18], ~D[2026-07-19]),
        segment("night_float", ~D[2026-07-20], ~D[2026-07-20])
      ]

      assert Enum.map(Ical.events_from_segments(segments, @name), & &1.dtstart) == [
               "20260718T060000",
               "20260719T180000"
             ]

      all_day = [
        segment("vacation", ~D[2026-07-18], ~D[2026-07-19]),
        segment("night_float", ~D[2026-07-20], ~D[2026-07-20])
      ]

      assert [%{dtstart: "20260718", dtend: "20260719"}, _night] =
               Ical.events_from_segments(all_day, @name)
    end

    test "covered segments are excluded and coverage segments are included" do
      segments = [
        segment("elective", ~D[2026-07-15], ~D[2026-07-16], %{
          covered_by: %{id: 1, resident_id: 2}
        }),
        %{
          rotation_type: "night_float",
          start_date: ~D[2026-07-17],
          end_date: ~D[2026-07-17],
          slot_index: -1,
          is_coverage: true,
          covered_by: nil,
          original_resident: %{id: 3, resident_id: 4}
        }
      ]

      assert Ical.events_from_segments(segments, @name) == [
               %{
                 uid: "seg-night_float-2026-07-17-2026-07-17@residency-schedule",
                 dtstart: "20260716T180000",
                 dtend: "20260717T060000",
                 summary: "Night Float – Strong"
               }
             ]
    end

    test "gap-fill summaries join literal tasks with an escaped separator" do
      gap =
        segment("qgenda_assignment", ~D[2026-07-21], ~D[2026-07-21], %{
          slot_index: -1,
          source_assignment_date: ~D[2026-07-21],
          source_tasks: ["Mystery Clinic PM", "Another, Task"]
        })

      assert Ical.events_from_segments([gap], @name) == [
               %{
                 uid: "seg-qgenda_assignment-2026-07-21@residency-schedule",
                 dtstart: "20260721",
                 dtend: "20260722",
                 summary: "Mystery Clinic PM\\; Another\\, Task"
               }
             ]
    end

    test "no segments yields no events" do
      assert Ical.events_from_segments([], @name) == []
    end

    test "events are emitted in the same order as the feed, unsorted input included" do
      segments = [
        segment("night_float", ~D[2026-07-20], ~D[2026-07-21]),
        segment("vacation", ~D[2026-07-06], ~D[2026-07-07]),
        segment("ambulatory", ~D[2026-07-08], ~D[2026-07-09])
      ]

      assert Enum.map(Ical.events_from_segments(segments, @name), & &1.dtstart) == [
               "20260706",
               "20260708T060000",
               "20260709T060000",
               "20260719T180000",
               "20260720T180000"
             ]
    end

    test "matches the VEVENT blocks that build_from_segments emits exactly" do
      segments = [
        segment("strong_obstetrics", ~D[2026-07-06], ~D[2026-07-12]),
        segment("elective", ~D[2026-07-13], ~D[2026-07-14], %{
          covered_by: %{id: 1, resident_id: 2}
        }),
        segment("vacation", ~D[2026-07-15], ~D[2026-07-19]),
        segment("night_float", ~D[2026-07-20], ~D[2026-07-22]),
        segment("strong_weekend_nights", ~D[2026-07-24], ~D[2026-07-24], %{
          source_assignment_date: ~D[2026-07-24],
          source_tasks: ["SMH Obstetrics Resident 1st Contact Night"]
        }),
        segment("qgenda_assignment", ~D[2026-07-27], ~D[2026-07-27], %{
          slot_index: -1,
          source_assignment_date: ~D[2026-07-27],
          source_tasks: ["Mystery Clinic PM", "Another; Task"]
        })
      ]

      events = Ical.events_from_segments(segments, @name)
      assert length(events) == 7 + 1 + 3 + 1 + 1
      assert events == parse_feed(Ical.build_from_segments(segments, @name))
    end
  end

  defp parse_feed(feed) do
    ~r/BEGIN:VEVENT\n(.*?)END:VEVENT/s
    |> Regex.scan(feed, capture: :all_but_first)
    |> Enum.map(fn [block] ->
      props =
        block
        |> String.split("\n", trim: true)
        |> Map.new(fn line ->
          [key, value] = String.split(line, ":", parts: 2)
          {key |> String.split(";") |> hd(), value}
        end)

      %{
        uid: props["UID"],
        dtstart: props["DTSTART"],
        dtend: props["DTEND"],
        summary: props["SUMMARY"]
      }
    end)
  end
end
