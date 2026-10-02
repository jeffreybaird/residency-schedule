defmodule ResidencySchedule.Importer.DateUpdateTest do
  use ResidencySchedule.DataCase

  alias ResidencySchedule.Importer.{NameNormalizer, ScheduleImporter}
  alias ResidencySchedule.{Residents, Schedules}

  setup do
    csv = csv([{"2026-12-01", "2027-01-31"}], ["R1-1,Original,FLOAT", "R1-2,Other,OB"])
    {:ok, summary, _} = ScheduleImporter.import_csv(csv)
    residents = Residents.list_residents_for_schedule(summary.schedule_id)
    %{schedule_id: summary.schedule_id, residents: residents}
  end

  test "replaces just selected resident days, splits boundaries, and is idempotent", context do
    before = snapshot(context.schedule_id)
    resident = Enum.find(context.residents, &(&1.position_code == "R1-1"))
    other = Enum.find(context.residents, &(&1.position_code == "R1-2"))
    patch = csv([{"2026-12-14", "2026-12-18"}], ["R1-1,Ignored,AMB"])

    assert {:ok, result, []} = update(patch)
    assert result.schedule_id == context.schedule_id
    after_update = Residents.get_resident!(resident.id)
    assert after_update.resident_id == resident.resident_id
    assert after_update.name == resident.name

    assert segments(after_update) == [
             {~D[2026-12-01], ~D[2026-12-13], "float"},
             {~D[2026-12-14], ~D[2026-12-18], "ambulatory"},
             {~D[2026-12-19], ~D[2027-01-31], "float"}
           ]

    assert Residents.get_resident!(other.id) == Enum.find(before, &(&1.id == other.id))
    assert {:ok, _, []} = update(patch)
    assert segments(Residents.get_resident!(resident.id)) == segments(after_update)
    assert length(Residents.list_residents_for_schedule(context.schedule_id)) == 2
  end

  test "blank, unknown, and omitted columns preserve days while OFF clears", context do
    patch =
      csv(
        [
          {"2026-12-14", "2026-12-14"},
          {"2026-12-15", "2026-12-15"},
          {"2026-12-16", "2026-12-16"},
          {"2026-12-17", "2026-12-17"}
        ],
        ["R1-1,Original,AMB,,Back-Up,OFF", "R1-2,Other,AMB"]
      )

    assert {:ok, _, warnings} = update(patch)
    assert {"R1-1", 2, "Back-Up"} in warnings
    first = resident(context.schedule_id, "R1-1")
    second = resident(context.schedule_id, "R1-2")
    assert type_on(first, ~D[2026-12-14]) == ["ambulatory"]
    assert type_on(first, ~D[2026-12-15]) == ["float"]
    assert type_on(first, ~D[2026-12-16]) == ["float"]
    assert type_on(first, ~D[2026-12-17]) == []
    assert type_on(second, ~D[2026-12-15]) == ["strong_obstetrics"]
    assert type_on(second, ~D[2026-12-17]) == ["strong_obstetrics"]
  end

  test "OFF-only file is a valid explicit clearing patch", context do
    assert {:ok, _, _} = update(csv([{"2026-12-14", "2026-12-18"}], ["R1-1,Original,OFF"]))
    assert type_on(resident(context.schedule_id, "R1-1"), ~D[2026-12-15]) == []
  end

  test "January patch targets selected year and uses that year's name normalization", context do
    patch = csv([{"2027-01-04", "2027-01-05"}], ["R1-1,Raw PDF Name,AMB"])
    before = snapshot(context.schedule_id)

    assert {:ok, prepared} =
             ScheduleImporter.prepare(patch, mode: :update_dates, academic_year: 2026)

    assert prepared.academic_year == 2026
    assert hd(prepared.parsed).name == NameNormalizer.normalize(2026, "R1-1", "Raw PDF Name")
    assert snapshot(context.schedule_id) == before
    assert {:ok, _, _} = update(patch)
    assert Schedules.get_by_year(2027) == nil
    assert type_on(resident(context.schedule_id, "R1-1"), ~D[2027-01-04]) == ["ambulatory"]
  end

  test "HNF keeps literal start while HWN clears source Sunday after Saturday shift", context do
    patch =
      csv([{"2026-12-14", "2026-12-14"}, {"2026-12-19", "2026-12-20"}], ["R1-1,Original,HNF,HWN"])

    assert {:ok, _, _} = update(patch)
    first = resident(context.schedule_id, "R1-1")
    assert type_on(first, ~D[2026-12-13]) == ["float"]
    assert type_on(first, ~D[2026-12-14]) == ["highland_night_float"]
    assert type_on(first, ~D[2026-12-19]) == ["highland_weekend_nights"]
    assert type_on(first, ~D[2026-12-20]) == []
    assert type_on(first, ~D[2026-12-21]) == ["float"]
  end

  test "review commit cannot change existing person links", context do
    patch = csv([{"2026-12-14", "2026-12-18"}], ["R1-1,Original,AMB"])

    assert {:ok, prepared} =
             ScheduleImporter.prepare(patch, mode: :update_dates, academic_year: 2026)

    first = resident(context.schedule_id, "R1-1")
    other = resident(context.schedule_id, "R1-2")
    before = snapshot(context.schedule_id)

    for link <- [:new, other.resident_id] do
      assert {:error, _} =
               ScheduleImporter.commit(prepared.parsed, 2026, %{"R1-1" => link},
                 mode: :update_dates
               )

      assert snapshot(context.schedule_id) == before
    end

    assert {:ok, _} =
             ScheduleImporter.commit(prepared.parsed, 2026, %{"R1-1" => first.resident_id},
               mode: :update_dates
             )
  end

  test "missing target, missing position and duplicate position reject without writes", context do
    before = snapshot(context.schedule_id)
    patch = csv([{"2026-12-14", "2026-12-18"}], ["R1-1,Original,AMB"])

    assert {:error, _} =
             ScheduleImporter.import_csv(patch, mode: :update_dates, academic_year: 2025)

    assert Schedules.get_by_year(2025) == nil

    for rows <- [
          ["R1-1,Original,AMB", "R1-99,Unknown,OB"],
          ["R1-1,Original,AMB", "R1-1,Duplicate,OB"]
        ] do
      assert {:error, _} = update(csv([{"2026-12-14", "2026-12-18"}], rows))
      assert snapshot(context.schedule_id) == before
    end
  end

  test "out of year, inverted and overlapping slots reject atomically", context do
    before = snapshot(context.schedule_id)

    for slots <- [
          [{"2026-06-29", "2026-07-03"}],
          [{"2027-06-28", "2027-07-02"}],
          [{"2026-12-18", "2026-12-14"}],
          [{"2026-12-14", "2026-12-18"}, {"2026-12-18", "2026-12-20"}]
        ] do
      assert {:error, _} = update(csv(slots, ["R1-1,Original,AMB,OB"]))
      assert snapshot(context.schedule_id) == before
    end
  end

  test "referenced rotations reject intersecting edits but preserve dependencies for other residents",
       context do
    first = resident(context.schedule_id, "R1-1")
    second = resident(context.schedule_id, "R1-2")
    rotation = hd(first.rotations)
    {:ok, user} = ResidencySchedule.Accounts.create_user(%{email: "coverage@urmc.rochester.edu"})

    request =
      Repo.insert!(%ResidencySchedule.ChangeRequests.ChangeRequest{
        rotation_id: rotation.id,
        covering_schedule_resident_id: second.id,
        requested_by_user_id: user.id,
        start_date: ~D[2026-12-10],
        end_date: ~D[2026-12-10]
      })

    {:ok, override} =
      ResidencySchedule.ShiftOverrides.create_override(%{
        rotation_id: rotation.id,
        covering_schedule_resident_id: second.id,
        override_start_date: ~D[2026-12-11],
        override_end_date: ~D[2026-12-11]
      })

    before = snapshot(context.schedule_id)

    assert {:error, _} =
             update(csv([{"2026-12-14", "2026-12-18"}], ["R1-1,Original,AMB", "R1-2,Other,NF"]))

    assert snapshot(context.schedule_id) == before
    assert {:ok, _, _} = update(csv([{"2026-12-14", "2026-12-18"}], ["R1-2,Other,NF"]))
    assert Repo.get!(ResidencySchedule.ChangeRequests.ChangeRequest, request.id) == request
    assert Repo.get!(ResidencySchedule.ShiftOverrides.ShiftOverride, override.id) == override
    assert Repo.get!(ResidencySchedule.Rotations.Rotation, rotation.id) == rotation
  end

  defp update(csv), do: ScheduleImporter.import_csv(csv, mode: :update_dates, academic_year: 2026)

  test "request alone prevents replacement of its referenced rotation", context do
    first = resident(context.schedule_id, "R1-1")
    second = resident(context.schedule_id, "R1-2")

    {:ok, user} =
      ResidencySchedule.Accounts.create_user(%{email: "request-only@urmc.rochester.edu"})

    request =
      Repo.insert!(%ResidencySchedule.ChangeRequests.ChangeRequest{
        rotation_id: hd(first.rotations).id,
        covering_schedule_resident_id: second.id,
        requested_by_user_id: user.id,
        start_date: ~D[2026-12-10],
        end_date: ~D[2026-12-10]
      })

    before = snapshot(context.schedule_id)
    assert {:error, _} = update(csv([{"2026-12-14", "2026-12-18"}], ["R1-1,Original,AMB"]))
    assert snapshot(context.schedule_id) == before
    assert Repo.get!(ResidencySchedule.ChangeRequests.ChangeRequest, request.id) == request
  end

  test "override alone prevents replacement of its referenced rotation", context do
    first = resident(context.schedule_id, "R1-1")
    second = resident(context.schedule_id, "R1-2")

    {:ok, override} =
      ResidencySchedule.ShiftOverrides.create_override(%{
        rotation_id: hd(first.rotations).id,
        covering_schedule_resident_id: second.id,
        override_start_date: ~D[2026-12-11],
        override_end_date: ~D[2026-12-11]
      })

    before = snapshot(context.schedule_id)
    assert {:error, _} = update(csv([{"2026-12-14", "2026-12-18"}], ["R1-1,Original,AMB"]))
    assert snapshot(context.schedule_id) == before
    assert Repo.get!(ResidencySchedule.ShiftOverrides.ShiftOverride, override.id) == override
  end

  test "date updates require a valid explicit target year", context do
    patch = csv([{"2027-01-04", "2027-01-05"}], ["R1-1,Original,AMB"])
    before = snapshot(context.schedule_id)

    for opts <- [
          [mode: :update_dates],
          [mode: :update_dates, academic_year: nil],
          [mode: :update_dates, academic_year: "invalid"]
        ] do
      assert {:error, _} = ScheduleImporter.prepare(patch, opts)
      assert {:error, _} = ScheduleImporter.import_csv(patch, opts)
      assert snapshot(context.schedule_id) == before
    end
  end

  defp snapshot(id),
    do:
      id
      |> Residents.list_residents_for_schedule()
      |> Enum.map(&Residents.get_resident!(&1.id))
      |> Enum.sort_by(& &1.id)

  defp resident(id, code), do: snapshot(id) |> Enum.find(&(&1.position_code == code))

  defp segments(resident),
    do:
      resident.rotations
      |> Enum.map(&{&1.start_date, &1.end_date, &1.rotation_type})
      |> Enum.sort()

  defp type_on(resident, date),
    do:
      resident.rotations
      |> Enum.filter(
        &(Date.compare(&1.start_date, date) != :gt and Date.compare(&1.end_date, date) != :lt)
      )
      |> Enum.map(& &1.rotation_type)

  defp csv(slots, rows) do
    starts = Enum.map_join(slots, ",", &elem(&1, 0))
    ends = Enum.map_join(slots, ",", &elem(&1, 1))
    Enum.join([",Dates," <> starts, ",," <> ends, ",,Events" | rows], "\n") <> "\n"
  end

  test "builder load and save preserve date updates, split FLOAT, explicit OFF and literal HNF",
       context do
    patch =
      csv(
        [
          {"2026-12-14", "2026-12-14"},
          {"2027-01-04", "2027-01-05"},
          {"2027-01-06", "2027-01-06"}
        ],
        ["R1-1,Original,HNF,AMB,OFF"]
      )

    assert {:ok, _, _} = update(patch)
    before = day_assignments(context.schedule_id)
    assert before[{"R1-1", ~D[2026-12-13]}] == ["float"]
    assert before[{"R1-1", ~D[2026-12-14]}] == ["highland_night_float"]
    assert before[{"R1-1", ~D[2027-01-04]}] == ["ambulatory"]
    assert before[{"R1-1", ~D[2027-01-06]}] == []

    assert {:ok, state} =
             ResidencySchedule.ScheduleBuilder.load_from_schedule(context.schedule_id)

    assert {:ok, result} = ResidencySchedule.ScheduleBuilder.save(state)
    assert result.schedule_id == context.schedule_id
    assert day_assignments(context.schedule_id) == before
  end

  defp day_assignments(schedule_id) do
    for person <- snapshot(schedule_id),
        date <- Date.range(~D[2026-07-01], ~D[2027-06-30]),
        into: %{} do
      {{person.position_code, date}, type_on(person, date) |> Enum.sort()}
    end
  end

  test "date update remains supported but editor refuses overlapping literal assignments",
       context do
    first = resident(context.schedule_id, "R1-1")

    assert {:ok, 1} =
             ResidencySchedule.Rotations.insert_rotations(first.id, [
               %{
                 slot_index: 9,
                 start_date: ~D[2026-12-10],
                 end_date: ~D[2026-12-13],
                 rotation_type: :highland_night_float
               }
             ])

    assert {:ok, _, _} = update(csv([{"2027-01-04", "2027-01-05"}], ["R1-1,Original,AMB"]))
    before = snapshot(context.schedule_id)

    assert {:error, reason} =
             ResidencySchedule.ScheduleBuilder.load_from_schedule(context.schedule_id)

    assert is_binary(reason)
    assert String.downcase(reason) =~ "overlap"
    assert snapshot(context.schedule_id) == before
  end
end
