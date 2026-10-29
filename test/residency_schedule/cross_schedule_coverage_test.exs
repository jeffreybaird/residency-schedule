defmodule ResidencySchedule.CrossScheduleCoverageTest do
  use ResidencySchedule.DataCase, async: true

  alias ResidencySchedule.{
    EffectiveSchedule,
    Repo,
    Residents,
    Rotations,
    Schedules,
    ShiftOverrides
  }

  alias ResidencySchedule.DetailedSchedules.{Activity, ActivitySource, ImportBatch}
  alias ResidencySchedule.Rotations.Rotation

  setup do
    {:ok, original_schedule} = Schedules.upsert_schedule(2026, "2026–2027")
    {:ok, covering_schedule} = Schedules.upsert_schedule(2027, "2027–2028")
    {:ok, unrelated_schedule} = Schedules.upsert_schedule(2028, "2028–2029")
    owner = resident(original_schedule, "Synthetic Owner")
    cover = resident(covering_schedule, "Synthetic Cover")
    unrelated = resident(unrelated_schedule, "Synthetic Unrelated")
    original = rotation(owner, "strong_obstetrics", ~D[2026-11-02], ~D[2026-11-06])
    elective = rotation(cover, "elective", ~D[2026-11-05], ~D[2026-11-05])
    other_elective = rotation(unrelated, "elective", ~D[2026-11-05], ~D[2026-11-05])

    activities =
      for member <- [cover, unrelated], date <- [~D[2026-11-03], ~D[2026-11-04]] do
        activity(member, date)
      end

    overrides =
      for date <- [~D[2026-11-03], ~D[2026-11-05]] do
        {:ok, override} =
          ShiftOverrides.create_override(%{
            rotation_id: original.id,
            covering_schedule_resident_id: cover.id,
            override_start_date: date,
            override_end_date: date
          })

        override
      end

    %{
      original_schedule: original_schedule,
      covering_schedule: covering_schedule,
      unrelated_schedule: unrelated_schedule,
      owner: owner,
      cover: cover,
      unrelated: unrelated,
      rotations: [original, elective, other_elective],
      activities: activities,
      overrides: overrides
    }
  end

  test "incoming coverage suppresses only its dated gap fill in every projection path", c do
    expected = [
      {"ultrasound", ~D[2026-11-04], ~D[2026-11-04]},
      {"elective", ~D[2026-11-05], ~D[2026-11-05]}
    ]

    assert spans(Rotations.projected_rotations_for_schedule(c.covering_schedule.id)) == expected
    assert spans(Rotations.projected_rotations_for_resident(c.cover.id)) == expected
    assert spans(Rotations.resident_schedule_data(c.cover).rotations) == expected

    range_rows =
      Rotations.projected_rotations_in_range_all_schedules(~D[2026-11-03], ~D[2026-11-05])
      |> Enum.filter(&(&1.schedule_resident_id == c.cover.id))

    assert spans(range_rows) == expected

    assert Rotations.list_schedule_date_slots(c.covering_schedule.id) ==
             [{0, ~D[2026-11-05], ~D[2026-11-05]}]

    assert_unchanged_records(c)
  end

  test "incoming coverage replaces own duty and agrees across individual and bulk effective reads",
       c do
    entries = Rotations.effective_segments_for_resident(c.cover.id)

    assert spans(entries) == [
             {"strong_obstetrics", ~D[2026-11-03], ~D[2026-11-03]},
             {"ultrasound", ~D[2026-11-04], ~D[2026-11-04]},
             {"strong_obstetrics", ~D[2026-11-05], ~D[2026-11-05]}
           ]

    for entry <- Enum.filter(entries, & &1.is_coverage) do
      assert entry.original_resident.id == c.owner.id
      assert entry.covered_by == nil
    end

    assert Rotations.effective_segments_for_schedule(c.covering_schedule.id) ==
             %{c.cover.id => entries}

    assert Rotations.resident_schedule_data(c.cover).effective_entries == entries
    assert Rotations.effective_segments_for_person(c.cover.resident_id) == entries
    assert_unchanged_records(c)
  end

  test "legacy daily records retain incoming and outgoing coverage identities", c do
    {:ok, cover_records} = EffectiveSchedule.for_schedule(c.covering_schedule.id, :legacy)
    {:ok, owner_records} = EffectiveSchedule.for_schedule(c.original_schedule.id, :legacy)

    for date <- [~D[2026-11-03], ~D[2026-11-05]] do
      assert %{duties: [coverage], off: nil} = record(cover_records, c.cover, date)
      assert coverage.kind == :coverage
      assert coverage.code == "strong_obstetrics"
      assert coverage.status == :working
      assert coverage.original_person_id == c.owner.resident_id

      assert %{duties: [covered]} = record(owner_records, c.owner, date)
      assert covered.code == "strong_obstetrics"
      assert covered.status == :covered
      assert covered.covered_by_person_id == c.cover.resident_id
    end

    assert %{duties: [%{kind: :gap_fill, code: "ultrasound"}]} =
             record(cover_records, c.cover, ~D[2026-11-04])

    assert {:ok, ^cover_records} = EffectiveSchedule.for_person(c.cover.resident_id, :legacy)
    assert_unchanged_records(c)
  end

  test "schedule range queries include incoming and outgoing coverage with inclusive boundaries",
       c do
    [first, last] = c.overrides

    for schedule <- [c.original_schedule, c.covering_schedule] do
      assert Enum.map(
               ShiftOverrides.list_overrides_for_schedule_in_range(
                 schedule.id,
                 ~D[2026-11-03],
                 ~D[2026-11-03]
               ),
               & &1.id
             ) == [first.id]

      assert Enum.map(
               ShiftOverrides.list_overrides_for_schedule_in_range(
                 schedule.id,
                 ~D[2026-11-04],
                 ~D[2026-11-05]
               ),
               & &1.id
             ) == [last.id]

      assert ShiftOverrides.list_overrides_for_schedule_in_range(
               schedule.id,
               ~D[2026-11-04],
               ~D[2026-11-04]
             ) == []
    end

    assert ShiftOverrides.list_overrides_for_schedule_in_range(
             c.unrelated_schedule.id,
             ~D[2026-11-03],
             ~D[2026-11-05]
           ) == []
  end

  test "incoming coverage suppresses own duty in schedule-scoped coworker rows", c do
    assert Rotations.list_effective_coworker_rows_for_type_in_range(
             c.covering_schedule.id,
             "elective",
             ~D[2026-11-05],
             ~D[2026-11-05]
           ) == []

    assert [row] =
             Rotations.list_effective_coworker_rows_for_type_in_range(
               c.unrelated_schedule.id,
               "elective",
               ~D[2026-11-05],
               ~D[2026-11-05]
             )

    assert row.resident.id == c.unrelated.id
    assert row.active_dates == MapSet.new([~D[2026-11-05]])
  end

  test "bulk incoming night coverage loads original schedule timing metadata", c do
    night =
      Repo.insert!(%Rotation{
        schedule_resident_id: c.owner.id,
        rotation_type: "night_float",
        start_date: ~D[2026-11-09],
        end_date: ~D[2026-11-13],
        slot_index: 1
      })

    {:ok, _override} =
      ShiftOverrides.create_override(%{
        rotation_id: night.id,
        covering_schedule_resident_id: c.cover.id,
        override_start_date: ~D[2026-11-10],
        override_end_date: ~D[2026-11-10]
      })

    bulk = Rotations.effective_segments_for_schedule(c.covering_schedule.id)[c.cover.id]
    assert bulk == Rotations.effective_segments_for_resident(c.cover.id)
    assert bulk == Rotations.resident_schedule_data(c.cover).effective_entries
    assert [coverage] = Enum.filter(bulk, &(&1.start_date == ~D[2026-11-10]))
    assert coverage.rotation_type == "night_float"
    assert coverage.is_coverage
    assert coverage.original_resident.id == c.owner.id
    assert Map.get(coverage, :source_assignment_date) == ~D[2026-11-08]

    assert [event] = ResidencySchedule.Ical.events_from_segments([coverage], c.cover.name)
    assert event.uid == "seg-night_float-2026-11-10-2026-11-10@residency-schedule"
    assert event.dtstart == "20261110T180000"
    assert event.dtend == "20261111T060000"
  end

  test "an unrelated schedule keeps its gap fills and own duty", c do
    expected = [
      {"ultrasound", ~D[2026-11-03], ~D[2026-11-03]},
      {"ultrasound", ~D[2026-11-04], ~D[2026-11-04]},
      {"elective", ~D[2026-11-05], ~D[2026-11-05]}
    ]

    assert spans(Rotations.projected_rotations_for_schedule(c.unrelated_schedule.id)) == expected
    entries = Rotations.effective_segments_for_schedule(c.unrelated_schedule.id)[c.unrelated.id]
    assert spans(entries) == expected
    refute Enum.any?(entries, & &1.is_coverage)
    assert Rotations.resident_schedule_data(c.unrelated).effective_entries == entries
    {:ok, records} = EffectiveSchedule.for_schedule(c.unrelated_schedule.id, :legacy)
    assert Enum.all?(records, &(&1.schedule_resident_id == c.unrelated.id))

    assert %{duties: [%{kind: :gap_fill, code: "ultrasound"}]} =
             record(records, c.unrelated, ~D[2026-11-03])

    assert %{duties: [%{kind: :rotation, code: "elective", status: :working}]} =
             record(records, c.unrelated, ~D[2026-11-05])

    assert_unchanged_records(c)
  end

  defp resident(schedule, name) do
    {:ok, member} =
      Residents.insert_resident(schedule.id, %{
        name: name,
        position_code: "R2-1",
        residency_year: 2,
        schedule_number: 1
      })

    member
  end

  defp rotation(member, type, first, last) do
    Repo.insert!(%Rotation{
      schedule_resident_id: member.id,
      rotation_type: type,
      start_date: first,
      end_date: last,
      slot_index: 0
    })
  end

  defp activity(member, date) do
    batch =
      Repo.insert!(%ImportBatch{
        schedule_id: member.schedule_id,
        created_by_id: ResidencySchedule.ScheduleFixtures.admin_user().id,
        fingerprint: Ecto.UUID.generate(),
        header_start: date,
        header_end: date
      })

    activity =
      Repo.insert!(%Activity{
        schedule_resident_id: member.id,
        date: date,
        raw_task: "Ultrasound"
      })

    Repo.insert!(%ActivitySource{
      activity_id: activity.id,
      batch_id: batch.id,
      source_sheet: "Synthetic",
      source_cell: "A1",
      raw_staff: member.name,
      display_name: member.name,
      previous_name: member.name
    })

    activity
  end

  defp spans(entries),
    do: Enum.map(entries, &{&1.rotation_type, &1.start_date, &1.end_date})

  defp record(records, member, date),
    do: Enum.find(records, &(&1.schedule_resident_id == member.id and &1.date == date))

  defp assert_unchanged_records(context) do
    for rotation <- context.rotations, do: assert(Repo.get!(Rotation, rotation.id) == rotation)
    for activity <- context.activities, do: assert(Repo.get!(Activity, activity.id) == activity)

    for override <- context.overrides,
        do: assert(Repo.get!(ShiftOverrides.ShiftOverride, override.id) == override)
  end
end
