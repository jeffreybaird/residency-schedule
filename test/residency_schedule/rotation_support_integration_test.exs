defmodule ResidencySchedule.RotationSupportIntegrationTest do
  use ResidencySchedule.DataCase

  alias ResidencySchedule.Importer.ScheduleImporter
  alias ResidencySchedule.{Residents, ScheduleBuilder, ScheduleEditor}
  alias ResidencySchedule.RotationSupportFixtures, as: Fixtures

  test "all new rotations persist through import, builder save and explicit date updates" do
    pairs = Fixtures.pairs()
    csv = Fixtures.csv(Enum.map(pairs, &elem(&1, 0)))
    assert {:ok, result, []} = ScheduleImporter.import_csv(csv)
    expected = Enum.map(pairs, &Atom.to_string(elem(&1, 1)))

    expected_assignments =
      Enum.with_index(expected, fn type, index ->
        date = Date.add(~D[2026-07-06], index)
        {type, date, date}
      end)

    assert types(result.schedule_id) == expected
    assert assignments(result.schedule_id) == expected_assignments
    assert {:ok, state} = ScheduleBuilder.load_from_schedule(result.schedule_id)
    assert {:ok, _} = ScheduleBuilder.save(state)
    assert types(result.schedule_id) == expected
    assert assignments(result.schedule_id) == expected_assignments

    assert {:ok, _, []} =
             ScheduleImporter.import_csv(csv, mode: :update_dates, academic_year: 2026)

    assert types(result.schedule_id) == expected
    assert assignments(result.schedule_id) == expected_assignments
  end

  test "builder save preserves noncanonical ordinary-import dates for existing clinical rotations" do
    csv =
      ",Dates,2026-07-08,2026-07-14\n,,2026-07-09,2026-07-16\n,,Events\nR4-1,Test Resident,OB,GYN\n"

    assert {:ok, result, []} = ScheduleImporter.import_csv(csv)

    expected = [
      {"strong_obstetrics", ~D[2026-07-08], ~D[2026-07-09]},
      {"strong_gynecology", ~D[2026-07-14], ~D[2026-07-16]}
    ]

    assert assignments(result.schedule_id) == expected
    assert {:ok, state} = ScheduleBuilder.load_from_schedule(result.schedule_id)
    assert {:ok, _} = ScheduleBuilder.save(state)
    assert assignments(result.schedule_id) == expected
  end

  test "canonical Highland adjusted bounds retain the annual builder calendar and shift dates" do
    csv =
      ",Dates,2026-06-29,2026-07-04\n,,2026-07-03,2026-07-05\n,,Events\nR4-1,Test Resident,HNF,HWN\n"

    assert {:ok, result, []} = ScheduleImporter.import_csv(csv)

    expected = [
      {"highland_night_float", ~D[2026-06-28], ~D[2026-07-03]},
      {"highland_weekend_nights", ~D[2026-07-04], ~D[2026-07-04]}
    ]

    assert assignments(result.schedule_id) == expected
    assert {:ok, state} = ScheduleBuilder.load_from_schedule(result.schedule_id)
    assert length(state.slots) == 100
    assert {:ok, _} = ScheduleBuilder.save(state)
    assert assignments(result.schedule_id) == expected
  end

  test "ordinary daily clinic overlapping adjusted HNF refuses unsafe annual-calendar fallback" do
    csv =
      ",Dates,2026-07-06,2026-07-07\n,,2026-07-06,2026-07-07\n,,Events\nR4-1,Test Resident,MFM,HNF\n"

    assert {:ok, result, []} = ScheduleImporter.import_csv(csv)

    expected = [
      {"mfm", ~D[2026-07-06], ~D[2026-07-06]},
      {"highland_night_float", ~D[2026-07-06], ~D[2026-07-07]}
    ]

    assert assignments(result.schedule_id) == expected
    assert {:error, reason} = ScheduleBuilder.load_from_schedule(result.schedule_id)
    assert String.downcase(reason) =~ "overlap"
    assert assignments(result.schedule_id) == expected
  end

  test "editor accepts and saves every new type with dates intact" do
    assert {:ok, result, []} = ScheduleImporter.import_csv(Fixtures.csv(["OB"]))
    [resident] = Residents.list_residents_for_schedule(result.schedule_id)
    [rotation] = Residents.get_resident!(resident.id).rotations

    for {_, type} <- Fixtures.pairs() do
      assert {:ok, state} = ScheduleEditor.load(result.schedule_id)

      attrs = %{
        rotation_type: Atom.to_string(type),
        start_date: rotation.start_date,
        end_date: rotation.end_date
      }

      assert {:ok, ^attrs} = ScheduleEditor.validate_assignment(state, attrs)

      assert {:ok, _} =
               ScheduleEditor.commit(state, [
                 %{action: :update, rotation_id: rotation.id, attrs: attrs}
               ])

      assert types(result.schedule_id) == [Atom.to_string(type)]
    end
  end

  defp types(id) do
    [resident] = Residents.list_residents_for_schedule(id)

    resident.id
    |> Residents.get_resident!()
    |> Map.fetch!(:rotations)
    |> Enum.sort_by(& &1.start_date, Date)
    |> Enum.map(& &1.rotation_type)
  end

  defp assignments(id) do
    [resident] = Residents.list_residents_for_schedule(id)

    resident.id
    |> Residents.get_resident!()
    |> Map.fetch!(:rotations)
    |> Enum.sort_by(& &1.start_date, Date)
    |> Enum.map(&{&1.rotation_type, &1.start_date, &1.end_date})
  end
end
