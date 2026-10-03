defmodule ResidencySchedule.ScheduleEditorTest do
  use ResidencySchedule.DataCase

  import Ecto.Query, only: [from: 2]

  alias ResidencySchedule.Importer.ScheduleImporter
  alias ResidencySchedule.Residents
  alias ResidencySchedule.Residents.{Resident, ScheduleResident}
  alias ResidencySchedule.Rotations.Rotation
  alias ResidencySchedule.ScheduleEditor
  alias ResidencySchedule.Schedules.Schedule

  setup do
    csv = ",Dates,2026-12-01\n,,2027-01-31\n,,Events\nR1-1,Original,FLOAT\nR1-2,Other,OB\n"
    {:ok, summary, _} = ScheduleImporter.import_csv(csv)
    [first, second] = Residents.list_residents_for_schedule(summary.schedule_id)
    original = hd(Residents.get_resident!(first.id).rotations)

    overlap =
      Repo.insert!(%Rotation{
        schedule_resident_id: first.id,
        slot_index: 131,
        rotation_type: "highland_night_float",
        start_date: ~D[2026-12-14],
        end_date: ~D[2026-12-18]
      })

    %{
      schedule_id: summary.schedule_id,
      first: first,
      second: second,
      original: original,
      overlap: overlap
    }
  end

  test "loads literal overlapping assignments regardless of source column", context do
    assert {:ok, state} = ScheduleEditor.load(context.schedule_id)
    assert state.schedule_id == context.schedule_id
    assert Enum.find(state.rotations, &(&1.id == context.original.id)) == context.original
    assert Enum.find(state.rotations, &(&1.id == context.overlap.id)) == context.overlap
    assert length(state.rotations) == 3
  end

  test "no-op save preserves all records, identities and timestamps", context do
    before = snapshot()
    assert {:ok, state} = ScheduleEditor.load(context.schedule_id)
    assert {:ok, _} = ScheduleEditor.commit(state, [])
    assert snapshot() == before
  end

  test "updates only the selected overlapping assignment and retains its ID and slot", context do
    before = snapshot()
    assert {:ok, state} = ScheduleEditor.load(context.schedule_id)

    assert {:ok, _} =
             ScheduleEditor.commit(state, [
               update(context.overlap, %{rotation_type: "ambulatory"})
             ])

    saved = Repo.get!(Rotation, context.overlap.id)
    assert saved.rotation_type == "ambulatory"
    assert saved.slot_index == 131
    assert saved.start_date == context.overlap.start_date
    assert saved.end_date == context.overlap.end_date
    assert Repo.get!(Rotation, context.original.id) == context.original

    assert snapshot_without_rotation(context.overlap.id) ==
             without_rotation(before, context.overlap.id)
  end

  test "can edit actual date bounds without moving or splitting other assignments", context do
    {:ok, state} = ScheduleEditor.load(context.schedule_id)
    before = snapshot_without_rotation(context.overlap.id)

    assert {:ok, _} =
             ScheduleEditor.commit(state, [
               update(context.overlap, %{start_date: ~D[2026-12-15], end_date: ~D[2026-12-20]})
             ])

    saved = Repo.get!(Rotation, context.overlap.id)
    assert saved.start_date == ~D[2026-12-15]
    assert saved.end_date == ~D[2026-12-20]
    assert snapshot_without_rotation(context.overlap.id) == before
  end

  test "add and delete affect exactly the explicit assignments", context do
    before = snapshot_without_rotation(context.overlap.id)
    {:ok, state} = ScheduleEditor.load(context.schedule_id)

    add = %{
      action: :add,
      schedule_resident_id: context.first.id,
      attrs: %{rotation_type: "post_call", start_date: ~D[2026-12-15], end_date: ~D[2026-12-15]}
    }

    assert {:ok, _} =
             ScheduleEditor.commit(state, [
               %{action: :delete, rotation_id: context.overlap.id},
               add
             ])

    assert Repo.get(Rotation, context.overlap.id) == nil
    added = Repo.one!(from r in Rotation, where: r.rotation_type == "post_call")
    assert added.schedule_resident_id == context.first.id
    assert added.start_date == ~D[2026-12-15]
    assert added.end_date == ~D[2026-12-15]
    assert snapshot_without_rotation(added.id) == before
  end

  test "rejects invalid inputs atomically after an otherwise valid change", context do
    {:ok, state} = ScheduleEditor.load(context.schedule_id)
    before = snapshot()

    for invalid <- [
          update(context.original, %{rotation_type: "not_a_rotation"}),
          update(context.original, %{start_date: "garbage"}),
          update(context.original, %{start_date: ~D[2027-02-01]}),
          update(context.original, %{end_date: nil}),
          update(context.original, %{schedule_resident_id: context.second.id}),
          %{action: :delete, rotation_id: "garbage"},
          %{action: :delete, rotation_id: -1},
          %{action: :unexpected, rotation_id: context.original.id},
          %{
            action: :add,
            schedule_resident_id: -1,
            attrs: %{
              rotation_type: "ambulatory",
              start_date: ~D[2026-12-01],
              end_date: ~D[2026-12-02]
            }
          }
        ] do
      assert {:error, _} =
               ScheduleEditor.commit(state, [
                 update(context.overlap, %{rotation_type: "ambulatory"}),
                 invalid
               ])

      assert snapshot() == before
    end
  end

  test "foreign schedule rotation and resident IDs cannot be edited", context do
    other_csv = ",Dates,2025-12-01\n,,2026-01-31\n,,Events\nR1-1,Previous,OB\n"
    {:ok, other, _} = ScheduleImporter.import_csv(other_csv)
    foreign = hd(Residents.list_residents_for_schedule(other.schedule_id))
    foreign_rotation = hd(Residents.get_resident!(foreign.id).rotations)
    {:ok, state} = ScheduleEditor.load(context.schedule_id)
    before = snapshot()

    for operation <- [
          update(foreign_rotation, %{rotation_type: "ambulatory"}),
          %{action: :delete, rotation_id: foreign_rotation.id},
          %{
            action: :add,
            schedule_resident_id: foreign.id,
            attrs: %{
              rotation_type: "ambulatory",
              start_date: ~D[2026-12-01],
              end_date: ~D[2026-12-02]
            }
          }
        ] do
      assert {:error, _} = ScheduleEditor.commit(state, [operation])
      assert snapshot() == before
    end
  end

  test "stale snapshots reject the entire patch even when timestamps match", context do
    {:ok, state} = ScheduleEditor.load(context.schedule_id)

    Repo.update_all(from(r in Rotation, where: r.id == ^context.original.id),
      set: [rotation_type: "oncology"]
    )

    assert Repo.get!(Rotation, context.original.id).updated_at == context.original.updated_at
    before = snapshot()

    assert {:error, _} =
             ScheduleEditor.commit(state, [
               update(context.overlap, %{rotation_type: "ambulatory"})
             ])

    assert snapshot() == before
    {:ok, fresh} = ScheduleEditor.load(context.schedule_id)

    assert {:ok, _} =
             ScheduleEditor.commit(fresh, [
               update(context.overlap, %{rotation_type: "ambulatory"})
             ])
  end

  test "new or removed assignments invalidate the loaded snapshot", context do
    {:ok, state} = ScheduleEditor.load(context.schedule_id)
    Repo.delete!(context.overlap)
    before = snapshot()

    assert {:error, _} =
             ScheduleEditor.commit(state, [
               update(context.original, %{rotation_type: "ambulatory"})
             ])

    assert snapshot() == before
  end

  test "new assignments and resident membership changes invalidate snapshot", context do
    {:ok, state} = ScheduleEditor.load(context.schedule_id)

    extra =
      Repo.insert!(%Rotation{
        schedule_resident_id: context.first.id,
        slot_index: -1,
        rotation_type: "post_call",
        start_date: ~D[2026-12-15],
        end_date: ~D[2026-12-15]
      })

    before = snapshot()

    assert {:error, _} =
             ScheduleEditor.commit(state, [update(context.original, %{rotation_type: "oncology"})])

    assert snapshot() == before
    Repo.delete!(extra)
    context.second |> Ecto.Changeset.change(position_code: "R1-3") |> Repo.update!()
    before = snapshot()

    assert {:error, _} =
             ScheduleEditor.commit(state, [update(context.original, %{rotation_type: "oncology"})])

    assert snapshot() == before
  end

  test "same-type overlaps and repeated negative columns retain separate IDs", context do
    twin =
      Repo.insert!(%Rotation{
        schedule_resident_id: context.first.id,
        slot_index: -1,
        rotation_type: "float",
        start_date: ~D[2026-12-15],
        end_date: ~D[2026-12-15]
      })

    other =
      Repo.insert!(%Rotation{
        schedule_resident_id: context.second.id,
        slot_index: -1,
        rotation_type: "post_call",
        start_date: ~D[2026-12-16],
        end_date: ~D[2026-12-16]
      })

    {:ok, state} = ScheduleEditor.load(context.schedule_id)
    assert Enum.find(state.rotations, &(&1.id == twin.id)) == twin
    assert Enum.find(state.rotations, &(&1.id == other.id)) == other
    before = snapshot()
    assert {:ok, _} = ScheduleEditor.commit(state, [])
    assert snapshot() == before
  end

  test "coverage request in any status prevents changing or deleting referenced rotation",
       context do
    {:ok, user} =
      ResidencySchedule.Accounts.create_user(%{email: "editor-coverage@urmc.rochester.edu"})

    for status <- [:pending, :approved, :denied, :cancelled] do
      request =
        Repo.insert!(%ResidencySchedule.ChangeRequests.ChangeRequest{
          rotation_id: context.overlap.id,
          covering_schedule_resident_id: context.second.id,
          requested_by_user_id: user.id,
          start_date: ~D[2026-12-15],
          end_date: ~D[2026-12-15],
          status: status
        })

      assert_protected(context)
      Repo.delete!(request)
    end
  end

  test "override prevents changing or deleting its referenced rotation", context do
    {:ok, _} =
      ResidencySchedule.ShiftOverrides.create_override(%{
        rotation_id: context.overlap.id,
        covering_schedule_resident_id: context.second.id,
        override_start_date: ~D[2026-12-15],
        override_end_date: ~D[2026-12-15]
      })

    assert_protected(context)
  end

  test "full 132-column combined upload loads every assignment and saves without loss" do
    csv = File.read!("output/winter-float/2026-2027-with-winter-float-upload.csv")
    {:ok, summary, _} = ScheduleImporter.import_csv(csv)
    before = snapshot()
    {:ok, state} = ScheduleEditor.load(summary.schedule_id)
    assert length(state.rotations) == 3042
    assert Enum.any?(state.rotations, &(&1.slot_index >= 100))
    assert {:ok, _} = ScheduleEditor.commit(state, [])
    assert snapshot() == before
  end

  test "missing or malformed schedules return errors" do
    for id <- [-1, nil, "invalid"] do
      assert {:error, _} = ScheduleEditor.load(id)
    end
  end

  test "duplicate operations for the same saved assignment reject atomically", context do
    {:ok, state} = ScheduleEditor.load(context.schedule_id)
    before = snapshot()
    delete = %{action: :delete, rotation_id: context.overlap.id}
    change = update(context.overlap, %{rotation_type: "ambulatory"})

    for duplicates <- [[delete, delete], [delete, change], [change, delete], [change, change]] do
      assert {:error, _} =
               ScheduleEditor.commit(state, [
                 update(context.original, %{rotation_type: "oncology"}) | duplicates
               ])

      assert snapshot() == before
    end
  end

  test "malformed commit state and operation containers return errors without writes", context do
    {:ok, state} = ScheduleEditor.load(context.schedule_id)
    before = snapshot()

    for {input, operations} <- [
          {nil, []},
          {%{}, []},
          {%{schedule_id: context.schedule_id}, []},
          {%{schedule_id: "invalid", snapshot: %{}}, []},
          {state, nil},
          {state, %{}},
          {state, [nil]},
          {state, [%{}]}
        ] do
      assert {:error, _} = ScheduleEditor.commit(input, operations)
      assert snapshot() == before
    end
  end

  test "assignment form validation handles strings, malformed dates and prohibited fields",
       context do
    {:ok, state} = ScheduleEditor.load(context.schedule_id)

    valid = %{
      "rotation_type" => "ambulatory",
      "start_date" => "2026-12-14",
      "end_date" => "2026-12-18"
    }

    assert {:ok,
            %{rotation_type: "ambulatory", start_date: ~D[2026-12-14], end_date: ~D[2026-12-18]}} =
             ScheduleEditor.validate_assignment(state, valid)

    for invalid <- [
          nil,
          [],
          %{},
          Map.put(valid, "rotation_type", "invalid"),
          Map.put(valid, "start_date", "invalid"),
          Map.put(valid, "start_date", "2026-12-19"),
          Map.put(valid, "start_date", "2025-12-14"),
          Map.put(valid, "end_date", "2028-12-18"),
          Map.put(valid, "schedule_resident_id", context.second.id),
          Map.put(valid, "slot_index", 0)
        ] do
      assert {:error, _} = ScheduleEditor.validate_assignment(state, invalid)
    end
  end

  defp assert_protected(context) do
    {:ok, state} = ScheduleEditor.load(context.schedule_id)
    before = snapshot()
    assert {:ok, _} = ScheduleEditor.commit(state, [])
    assert snapshot() == before

    for operation <- [
          update(context.overlap, %{rotation_type: "ambulatory"}),
          %{action: :delete, rotation_id: context.overlap.id}
        ] do
      assert {:error, reason} =
               ScheduleEditor.commit(state, [
                 update(context.original, %{rotation_type: "oncology"}),
                 operation
               ])

      assert is_binary(reason)
      assert snapshot() == before
    end

    assert {:ok, _} =
             ScheduleEditor.commit(state, [update(context.original, %{rotation_type: "oncology"})])
  end

  defp update(rotation, attrs), do: %{action: :update, rotation_id: rotation.id, attrs: attrs}

  defp snapshot do
    for schema <- [
          Schedule,
          Resident,
          ScheduleResident,
          Rotation,
          ResidencySchedule.ChangeRequests.ChangeRequest,
          ResidencySchedule.ShiftOverrides.ShiftOverride
        ],
        into: %{} do
      {schema, Repo.all(from row in schema, order_by: row.id)}
    end
  end

  defp snapshot_without_rotation(id), do: without_rotation(snapshot(), id)

  defp without_rotation(snapshot, id),
    do: Map.update!(snapshot, Rotation, &Enum.reject(&1, fn row -> row.id == id end))
end
