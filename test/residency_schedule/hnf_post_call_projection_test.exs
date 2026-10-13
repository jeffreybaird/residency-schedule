defmodule ResidencySchedule.HnfPostCallProjectionTest do
  use ResidencySchedule.DataCase, async: true

  alias ResidencySchedule.{Residents, Rotations, Schedules, ShiftOverrides}

  setup do
    {:ok, schedule} = Schedules.upsert_schedule(2026, "2026–2027")
    resident = resident(schedule, "R1-1")
    other = resident(schedule, "R1-2")
    %{schedule: schedule, resident: resident, other: other}
  end

  test "loaded overlaps are corrected throughout projected and effective reads without writes",
       c do
    post_call = insert(c.resident, :post_call, ~D[2026-11-07], ~D[2026-11-08], 0)
    hnf = insert(c.resident, :highland_night_float, ~D[2026-11-08], ~D[2026-11-13], 1)
    raw = Rotations.list_rotations_for_resident(c.resident.id)

    expected = [
      {post_call.id, "post_call", ~D[2026-11-07], ~D[2026-11-07], 0},
      {hnf.id, "highland_night_float", ~D[2026-11-08], ~D[2026-11-13], 1}
    ]

    assert spans(Rotations.projected_rotations_for_resident(c.resident.id)) == expected
    assert spans(Rotations.projected_rotations_for_schedule(c.schedule.id)) == expected
    assert spans(Rotations.resident_schedule_data(c.resident).rotations) == expected

    assert types(Rotations.projected_rotations_for_date(~D[2026-11-08], c.schedule.id)) == [
             "highland_night_float"
           ]

    assert types(
             Rotations.effective_day_assignments(
               Rotations.projected_rotations_for_date(~D[2026-11-08], c.schedule.id),
               []
             )
           ) == ["highland_night_float"]

    assert types(
             Rotations.projected_rotations_in_range_all_schedules(~D[2026-11-08], ~D[2026-11-08])
           ) == ["highland_night_float"]

    effective = Rotations.effective_segments_for_resident(c.resident.id)

    assert effective_spans(effective) == [
             {"post_call", ~D[2026-11-07], ~D[2026-11-07]},
             {"highland_night_float", ~D[2026-11-08], ~D[2026-11-13]}
           ]

    assert Rotations.effective_segments_for_schedule(c.schedule.id)[c.resident.id] == effective
    assert Rotations.resident_schedule_data(c.resident).effective_entries == effective
    assert Rotations.list_rotations_for_resident(c.resident.id) == raw
    assert Rotations.get_rotation(post_call.id).end_date == ~D[2026-11-08]
  end

  test "projection removes a fully overlapped P and splits an interior HNF interval", c do
    full = insert(c.resident, :post_call, ~D[2026-11-08], ~D[2026-11-08], 0)
    split = insert(c.resident, :post_call, ~D[2026-11-07], ~D[2026-11-14], 2)
    hnf = insert(c.resident, :highland_night_float, ~D[2026-11-08], ~D[2026-11-13], 1)

    projected = Rotations.projected_rotations_for_resident(c.resident.id)
    refute Enum.any?(projected, &(&1.id == full.id))

    assert spans(Enum.filter(projected, &(&1.id == split.id))) == [
             {split.id, "post_call", ~D[2026-11-07], ~D[2026-11-07], 2},
             {split.id, "post_call", ~D[2026-11-14], ~D[2026-11-14], 2}
           ]

    assert Enum.find(projected, &(&1.id == hnf.id)).start_date == hnf.start_date
    assert length(Rotations.list_rotations_for_resident(c.resident.id)) == 3
  end

  test "HNF removes only its own resident's P, preserving working conflicts and other schedules",
       c do
    insert(c.resident, :highland_night_float, ~D[2026-11-08], ~D[2026-11-13], 1)
    working = insert(c.resident, :strong_obstetrics, ~D[2026-11-07], ~D[2026-11-08], 0)
    other_p = insert(c.other, :post_call, ~D[2026-11-07], ~D[2026-11-08], 0)
    {:ok, another_schedule} = Schedules.upsert_schedule(2025, "2025–2026")
    other_year = resident(another_schedule, "R1-1")
    other_year_p = insert(other_year, :post_call, ~D[2026-11-07], ~D[2026-11-08], 0)

    assert Enum.find(
             Rotations.projected_rotations_for_resident(c.resident.id),
             &(&1.id == working.id)
           ).end_date == ~D[2026-11-08]

    assert spans(Rotations.projected_rotations_for_resident(c.other.id)) == spans([other_p])

    assert spans(Rotations.projected_rotations_for_resident(other_year.id)) ==
             spans([other_year_p])

    assert Rotations.projected_rotations_for_resident(-1) == []
    assert Rotations.projected_rotations_for_schedule(-1) == []
  end

  test "HNF override remains attached to its original stored assignment identity", c do
    covering_p = insert(c.other, :post_call, ~D[2026-11-08], ~D[2026-11-08], 0)
    post_call = insert(c.resident, :post_call, ~D[2026-11-07], ~D[2026-11-08], 0)
    hnf = insert(c.resident, :highland_night_float, ~D[2026-11-08], ~D[2026-11-13], 1)

    {:ok, override} =
      ShiftOverrides.create_override(%{
        rotation_id: hnf.id,
        covering_schedule_resident_id: c.other.id,
        override_start_date: ~D[2026-11-08],
        override_end_date: ~D[2026-11-08]
      })

    projected = Rotations.projected_rotations_for_resident(c.resident.id)
    assert Enum.find(projected, &(&1.id == hnf.id)).id == override.rotation_id
    assert Enum.find(projected, &(&1.id == post_call.id)).end_date == ~D[2026-11-07]

    assert Enum.any?(Rotations.effective_segments_for_resident(c.other.id), fn segment ->
             segment.is_coverage and segment.rotation_type == "highland_night_float" and
               segment.start_date == ~D[2026-11-08] and segment.end_date == ~D[2026-11-08]
           end)

    assert Rotations.get_rotation(hnf.id).start_date == hnf.start_date
    assert spans(Rotations.projected_rotations_for_resident(c.other.id)) == spans([covering_p])
  end

  test "a fully masked Post Call retains its stored override without producing projected P", c do
    post_call = insert(c.resident, :post_call, ~D[2026-11-08], ~D[2026-11-08], 0)
    insert(c.resident, :highland_night_float, ~D[2026-11-08], ~D[2026-11-13], 1)

    {:ok, override} =
      ShiftOverrides.create_override(%{
        rotation_id: post_call.id,
        covering_schedule_resident_id: c.other.id,
        override_start_date: ~D[2026-11-08],
        override_end_date: ~D[2026-11-08]
      })

    assert types(Rotations.projected_rotations_for_resident(c.resident.id)) == [
             "highland_night_float"
           ]

    assert Rotations.get_rotation(post_call.id).end_date == ~D[2026-11-08]

    assert Enum.any?(
             ShiftOverrides.list_overrides_for_schedule(c.schedule.id),
             &(&1.id == override.id and &1.rotation_id == post_call.id)
           )
  end

  defp resident(schedule, position) do
    {:ok, resident} =
      Residents.insert_resident(schedule.id, %{
        position_code: position,
        residency_year: 1,
        schedule_number: String.last(position) |> String.to_integer(),
        name: "Example " <> position
      })

    resident
  end

  defp insert(resident, type, start_date, end_date, index) do
    {:ok, _} =
      Rotations.insert_rotations(resident.id, [
        %{rotation_type: type, start_date: start_date, end_date: end_date, slot_index: index}
      ])

    Enum.find(Rotations.list_rotations_for_resident(resident.id), &(&1.slot_index == index))
  end

  defp spans(rotations),
    do: Enum.map(rotations, &{&1.id, &1.rotation_type, &1.start_date, &1.end_date, &1.slot_index})

  defp types(rotations), do: Enum.map(rotations, & &1.rotation_type) |> Enum.sort()

  defp effective_spans(rotations),
    do: Enum.map(rotations, &{&1.rotation_type, &1.start_date, &1.end_date})
end
