defmodule ResidencySchedule.StrongNightProjectionTest do
  use ResidencySchedule.DataCase, async: true

  doctest ResidencySchedule.Rotations.StrongNightBoundaries

  alias ResidencySchedule.{
    DetailedSchedules,
    Repo,
    Residents,
    Rotations,
    Schedules,
    ShiftOverrides
  }

  alias ResidencySchedule.DetailedSchedules.{Activity, ActivitySource, ImportBatch}
  alias ResidencySchedule.Rotations.{Rotation, StrongNightBoundaries}

  setup do
    {:ok, schedule} = Schedules.upsert_schedule(2026, "2026–2027")
    ambulatory = resident(schedule, 1)
    night_float = resident(schedule, 2)

    insert(ambulatory, [
      {:ambulatory, ~D[2026-11-02], ~D[2026-11-06]},
      {:strong_weekend_nights, ~D[2026-11-07], ~D[2026-11-08]},
      {:ambulatory, ~D[2026-11-09], ~D[2026-11-13]},
      {:strong_weekend_nights, ~D[2026-11-14], ~D[2026-11-15]},
      {:night_float, ~D[2026-11-16], ~D[2026-11-20]}
    ])

    insert(night_float, [
      {:night_float, ~D[2026-11-02], ~D[2026-11-06]},
      {:post_call, ~D[2026-11-07], ~D[2026-11-08]},
      {:night_float, ~D[2026-11-09], ~D[2026-11-13]},
      {:post_call, ~D[2026-11-14], ~D[2026-11-15]},
      {:night_float, ~D[2026-11-16], ~D[2026-11-20]}
    ])

    %{schedule: schedule, ambulatory: ambulatory, night_float: night_float}
  end

  test "stored Nov 2–19 slots project to Amb Mon–Thu, weekend nights Fri–Sat and NF Sun–Thu without a reimport",
       c do
    raw = Rotations.list_rotations_for_resident(c.ambulatory.id)

    expected = [
      {"ambulatory", ~D[2026-11-02], ~D[2026-11-05]},
      {"strong_weekend_nights", ~D[2026-11-06], ~D[2026-11-07]},
      {"ambulatory", ~D[2026-11-09], ~D[2026-11-12]},
      {"strong_weekend_nights", ~D[2026-11-13], ~D[2026-11-14]},
      {"night_float", ~D[2026-11-15], ~D[2026-11-19]},
      {"post_call", ~D[2026-11-20], ~D[2026-11-20]}
    ]

    assert spans(Rotations.projected_rotations_for_resident(c.ambulatory.id)) == expected
    assert spans(Rotations.effective_segments_for_resident(c.ambulatory.id)) == expected

    assert spans(Rotations.effective_segments_for_schedule(c.schedule.id)[c.ambulatory.id]) ==
             expected

    data = Rotations.resident_schedule_data(c.ambulatory)
    assert spans(data.rotations) == expected
    assert spans(data.effective_entries) == expected

    assert spans(
             Rotations.projected_rotations_for_schedule(c.schedule.id)
             |> Enum.filter(&(&1.schedule_resident_id == c.ambulatory.id))
           ) == expected

    assert Rotations.list_rotations_for_resident(c.ambulatory.id) == raw

    assert Enum.all?(raw, fn rotation ->
             stored = Rotations.get_rotation(rotation.id)

             {stored.rotation_type, stored.start_date, stored.end_date} ==
               {rotation.rotation_type, rotation.start_date, rotation.end_date}
           end)

    assert DetailedSchedules.list_for_resident(c.ambulatory.id, ~D[2026-11-06]) == []
  end

  test "the usual night float team works Sunday through Thursday with Friday and Saturday post call",
       c do
    assert spans(Rotations.effective_segments_for_resident(c.night_float.id)) == [
             {"night_float", ~D[2026-11-01], ~D[2026-11-05]},
             {"post_call", ~D[2026-11-06], ~D[2026-11-07]},
             {"night_float", ~D[2026-11-08], ~D[2026-11-12]},
             {"post_call", ~D[2026-11-13], ~D[2026-11-14]},
             {"night_float", ~D[2026-11-15], ~D[2026-11-19]},
             {"post_call", ~D[2026-11-20], ~D[2026-11-20]}
           ]
  end

  test "narrow date reads include displaced Sunday NF and Friday SWN without needing adjacent slots in the requested window",
       c do
    for {date, ambulatory_type, nf_type} <- [
          {~D[2026-11-05], "ambulatory", "night_float"},
          {~D[2026-11-06], "strong_weekend_nights", "post_call"},
          {~D[2026-11-07], "strong_weekend_nights", "post_call"},
          {~D[2026-11-08], nil, "night_float"},
          {~D[2026-11-09], "ambulatory", "night_float"},
          {~D[2026-11-13], "strong_weekend_nights", "post_call"},
          {~D[2026-11-14], "strong_weekend_nights", "post_call"},
          {~D[2026-11-15], "night_float", "night_float"},
          {~D[2026-11-19], "night_float", "night_float"}
        ] do
      expected =
        [{c.ambulatory.id, ambulatory_type}, {c.night_float.id, nf_type}]
        |> Enum.reject(&is_nil(elem(&1, 1)))
        |> Enum.sort()

      projected = Rotations.projected_rotations_for_date(date, c.schedule.id)
      assert day_rows(projected, date) == expected

      assert day_rows(
               Rotations.projected_rotations_in_range_all_schedules(date, date),
               date
             ) == expected

      assert Rotations.effective_day_assignments(projected, [])
             |> Enum.map(&{&1.resident.id, &1.rotation_type})
             |> Enum.sort() == expected
    end
  end

  test "Friday literal Strong duties are preserved and ambulatory duty remains weekend nights",
       c do
    task = "SMH Obstetrics Resident 1st Contact Night"
    amb_activity = add_activity(c.ambulatory, ~D[2026-11-06], task)
    nf_activity = add_activity(c.night_float, ~D[2026-11-06], task)

    assert day_rows(Rotations.projected_rotations_for_schedule(c.schedule.id), ~D[2026-11-06]) ==
             Enum.sort([
               {c.ambulatory.id, "strong_weekend_nights"},
               {c.night_float.id, "night_float"}
             ])

    assert Repo.get!(Activity, amb_activity.id) == amb_activity
    assert Repo.get!(Activity, nf_activity.id) == nf_activity
  end

  test "approved Friday NF coverage retains its stored rotation identity", c do
    [nf | _] = Rotations.list_rotations_for_resident(c.night_float.id)
    covering = resident(c.schedule, 3)

    {:ok, override} =
      ShiftOverrides.create_override(%{
        rotation_id: nf.id,
        covering_schedule_resident_id: covering.id,
        override_start_date: ~D[2026-11-06],
        override_end_date: ~D[2026-11-06]
      })

    assert Enum.any?(Rotations.effective_segments_for_resident(c.night_float.id), fn entry ->
             entry.rotation_type == "night_float" and not is_nil(entry.covered_by) and
               entry.covered_by.id == covering.id and
               ~D[2026-11-06] in Date.range(entry.start_date, entry.end_date)
           end)

    assert Enum.any?(Rotations.effective_segments_for_resident(covering.id), fn entry ->
             entry.is_coverage and entry.rotation_type == "night_float" and
               entry.start_date == ~D[2026-11-06] and entry.end_date == ~D[2026-11-06]
           end)

    assert Rotations.get_rotation(nf.id).start_date == ~D[2026-11-02]
    assert override.rotation_id == nf.id
  end

  test "approved ambulatory Friday and post-call Sunday overrides keep their actual dates and original source types",
       c do
    amb = Enum.find(Rotations.list_rotations_for_resident(c.ambulatory.id), &(&1.slot_index == 0))

    post_call =
      Enum.find(Rotations.list_rotations_for_resident(c.night_float.id), &(&1.slot_index == 1))

    covering = resident(c.schedule, 3)

    for {rotation, date, type, owner} <- [
          {amb, ~D[2026-11-06], "ambulatory", c.ambulatory},
          {post_call, ~D[2026-11-08], "post_call", c.night_float}
        ] do
      {:ok, override} =
        ShiftOverrides.create_override(%{
          rotation_id: rotation.id,
          covering_schedule_resident_id: covering.id,
          override_start_date: date,
          override_end_date: date
        })

      assert day_rows(Rotations.projected_rotations_for_resident(owner.id), date) == [
               {owner.id, type}
             ]

      assert Enum.any?(Rotations.effective_segments_for_resident(owner.id), fn entry ->
               entry.rotation_type == type and not is_nil(entry.covered_by) and
                 entry.covered_by.id == covering.id and
                 date in Date.range(entry.start_date, entry.end_date)
             end)

      assert Enum.any?(Rotations.effective_segments_for_resident(covering.id), fn entry ->
               entry.is_coverage and entry.rotation_type == type and
                 entry.start_date == date and entry.end_date == date
             end)

      assert override.rotation_id == rotation.id
      assert override.override_start_date == date
      assert override.override_end_date == date
      assert Rotations.get_rotation(rotation.id).start_date == rotation.start_date
    end
  end

  test "already aligned Strong slots and unrelated ambulatory, Highland and other-site work retain their dates",
       c do
    aligned = resident(c.schedule, 3)
    other = resident(c.schedule, 4)

    insert(aligned, [
      {:ambulatory, ~D[2026-11-02], ~D[2026-11-05]},
      {:strong_weekend_nights, ~D[2026-11-06], ~D[2026-11-07]},
      {:night_float, ~D[2026-11-08], ~D[2026-11-12]},
      {:post_call, ~D[2026-11-13], ~D[2026-11-14]}
    ])

    insert(other, [
      {:ambulatory, ~D[2026-11-02], ~D[2026-11-06]},
      {:highland_weekend_nights, ~D[2026-11-07], ~D[2026-11-07]},
      {:highland_night_float, ~D[2026-11-08], ~D[2026-11-13]},
      {:strong_obstetrics, ~D[2026-11-14], ~D[2026-11-15]}
    ])

    for resident <- [aligned, other] do
      assert spans(Rotations.projected_rotations_for_resident(resident.id)) ==
               spans(Rotations.list_rotations_for_resident(resident.id))
    end
  end

  test "an isolated canonical NF slot projects Sunday–Thursday while arbitrary midweek Strong spans keep their dates",
       c do
    isolated = resident(c.schedule, 3)
    arbitrary = resident(c.schedule, 4)
    insert(isolated, [{:night_float, ~D[2026-12-07], ~D[2026-12-11]}])

    insert(arbitrary, [
      {:night_float, ~D[2026-12-08], ~D[2026-12-10]},
      {:strong_weekend_nights, ~D[2026-12-15], ~D[2026-12-16]}
    ])

    assert spans(Rotations.projected_rotations_for_resident(isolated.id)) == [
             {"night_float", ~D[2026-12-06], ~D[2026-12-10]},
             {"post_call", ~D[2026-12-11], ~D[2026-12-11]}
           ]

    assert spans(Rotations.projected_rotations_for_resident(arbitrary.id)) ==
             spans(Rotations.list_rotations_for_resident(arbitrary.id))
  end

  test "unrelated rotations sharing source endpoints cannot hide the ambulatory weekend pair" do
    ambulatory = pure_rotation(1, "ambulatory", ~D[2026-11-02], ~D[2026-11-06])
    weekend = pure_rotation(2, "strong_weekend_nights", ~D[2026-11-07], ~D[2026-11-08])
    friday_vacation = pure_rotation(3, "vacation", ~D[2026-11-06], ~D[2026-11-06])
    saturday_vacation = pure_rotation(4, "vacation", ~D[2026-11-07], ~D[2026-11-07])

    expected = [
      {"ambulatory", ~D[2026-11-02], ~D[2026-11-05]},
      {"strong_weekend_nights", ~D[2026-11-06], ~D[2026-11-07]},
      {"vacation", ~D[2026-11-06], ~D[2026-11-06]},
      {"vacation", ~D[2026-11-07], ~D[2026-11-07]}
    ]

    for rotations <- [
          [ambulatory, friday_vacation, weekend, saturday_vacation],
          [saturday_vacation, weekend, friday_vacation, ambulatory],
          [weekend, saturday_vacation, ambulatory, friday_vacation]
        ] do
      assert StrongNightBoundaries.project(rotations, [], []) |> spans() |> Enum.sort() ==
               Enum.sort(expected)
    end
  end

  test "literal Friday activity does not remove unrelated post-call work outside canonical NF" do
    post_call = pure_rotation(1, "post_call", ~D[2026-11-06], ~D[2026-11-07])

    activity = %{
      schedule_resident_id: 99,
      date: ~D[2026-11-06],
      raw_task: "SMH Obstetrics Resident 1st Contact Night"
    }

    assert StrongNightBoundaries.project([post_call], [activity], []) |> spans() ==
             spans([post_call])
  end

  test "an existing irregular post-call span covering the vacated Friday is not duplicated" do
    nf = pure_rotation(1, "night_float", ~D[2026-11-02], ~D[2026-11-06])
    post_call = pure_rotation(2, "post_call", ~D[2026-11-06], ~D[2026-11-08])

    assert StrongNightBoundaries.project([nf, post_call], [], []) |> spans() == [
             {"night_float", ~D[2026-11-01], ~D[2026-11-05]},
             {"post_call", ~D[2026-11-06], ~D[2026-11-08]}
           ]
  end

  defp pure_rotation(id, type, first, last),
    do: %Rotation{
      id: id,
      schedule_resident_id: 99,
      rotation_type: type,
      start_date: first,
      end_date: last,
      slot_index: id
    }

  defp resident(schedule, number) do
    {:ok, resident} =
      Residents.insert_resident(schedule.id, %{
        name: "Example #{number}",
        position_code: "R2-#{number}",
        residency_year: 2,
        schedule_number: number
      })

    resident
  end

  defp insert(resident, slots) do
    slots
    |> Enum.with_index()
    |> Enum.map(fn {{type, first, last}, index} ->
      %{rotation_type: type, start_date: first, end_date: last, slot_index: index}
    end)
    |> then(&Rotations.insert_rotations(resident.id, &1))
  end

  defp add_activity(resident, date, task) do
    admin = ResidencySchedule.ScheduleFixtures.admin_user()

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

  defp spans(rotations),
    do:
      rotations
      |> Enum.sort_by(& &1.start_date, Date)
      |> Enum.map(&{&1.rotation_type, &1.start_date, &1.end_date})

  defp day_rows(rotations, date),
    do:
      rotations
      |> Enum.filter(&(date in Date.range(&1.start_date, &1.end_date)))
      |> Enum.map(&{&1.schedule_resident_id, &1.rotation_type})
      |> Enum.sort()
end
