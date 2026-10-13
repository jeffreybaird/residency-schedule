defmodule ResidencySchedule.Rotations.HighlandPostCallTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Rotations.{HighlandPostCall, Rotation}

  doctest HighlandPostCall

  test "empty and unmatched inputs are unchanged" do
    assert HighlandPostCall.normalize([]) == []
    post_call = rotation(:post_call, ~D[2026-11-07], ~D[2026-11-08])
    working = rotation(:strong_obstetrics, ~D[2026-11-07], ~D[2026-11-08])
    assert HighlandPostCall.normalize([post_call, working]) == [post_call, working]
  end

  test "HNF before and after Post Call leave it unchanged" do
    post_call = rotation(:post_call, ~D[2026-11-07], ~D[2026-11-08])
    earlier = rotation(:highland_night_float, ~D[2026-11-01], ~D[2026-11-06])
    later = rotation(:highland_night_float, ~D[2026-11-09], ~D[2026-11-13])
    assert HighlandPostCall.normalize([post_call, earlier, later]) == [post_call, earlier, later]
  end

  test "multiple HNF cuts retain every unoccupied Post Call day and are idempotent" do
    post_call = rotation(:post_call, ~D[2026-11-01], ~D[2026-11-20])
    prefix = rotation(:highland_night_float, ~D[2026-10-31], ~D[2026-11-03])
    middle = rotation(:highland_night_float, ~D[2026-11-08], ~D[2026-11-13])
    suffix = rotation(:highland_night_float, ~D[2026-11-18], ~D[2026-11-21])
    normalized = HighlandPostCall.normalize([post_call, prefix, middle, suffix])

    assert Enum.filter(normalized, &(&1.rotation_type == :post_call)) == [
             %{post_call | start_date: ~D[2026-11-04], end_date: ~D[2026-11-07]},
             %{post_call | start_date: ~D[2026-11-14], end_date: ~D[2026-11-17]}
           ]

    assert HighlandPostCall.normalize(normalized) == normalized
  end

  test "persisted string types preserve struct identity and resident isolation" do
    post_call = %Rotation{
      id: 7,
      schedule_resident_id: 1,
      slot_index: 0,
      rotation_type: "post_call",
      start_date: ~D[2026-11-07],
      end_date: ~D[2026-11-08]
    }

    own_hnf = %Rotation{
      id: 8,
      schedule_resident_id: 1,
      slot_index: 1,
      rotation_type: "highland_night_float",
      start_date: ~D[2026-11-08],
      end_date: ~D[2026-11-13]
    }

    other_p = %{post_call | id: 9, schedule_resident_id: 2}

    assert HighlandPostCall.normalize([post_call, own_hnf, other_p]) == [
             %{post_call | end_date: ~D[2026-11-07]},
             own_hnf,
             other_p
           ]
  end

  test "a containing HNF suppresses Post Call completely while retaining working assignments" do
    post_call = rotation(:post_call, ~D[2026-11-09], ~D[2026-11-10])
    hnf = rotation(:highland_night_float, ~D[2026-11-08], ~D[2026-11-13])
    working = %{post_call | rotation_type: :strong_obstetrics}
    assert HighlandPostCall.normalize([post_call, hnf, working]) == [hnf, working]
  end

  defp rotation(type, start_date, end_date) do
    %{rotation_type: type, start_date: start_date, end_date: end_date, slot_index: 0}
  end
end
