defmodule ResidencySchedule.DemoSeedTest do
  use ResidencySchedule.DataCase

  alias ResidencySchedule.Importer.CsvParser
  alias ResidencySchedule.Importer.ScheduleImporter
  alias ResidencySchedule.Release
  alias ResidencySchedule.Residents
  alias ResidencySchedule.Rotations.{Rotation, StrongNightBoundaries}
  alias ResidencySchedule.Schedules

  @baseline_path "test/fixtures/demo_schedule_baseline.csv"

  describe "demo_csv_path/0" do
    test "points at a readable CSV inside the application" do
      assert File.exists?(Release.demo_csv_path())
    end
  end

  describe "demo schedule fixture" do
    setup do
      # Demo mode is what preserves the invented names: the fixture covers the
      # current academic year, which NameNormalizer maps to real residents.
      set_demo_mode(true)
      csv = File.read!(Release.demo_csv_path())
      {:ok, result, warnings} = ScheduleImporter.import_csv(csv)
      %{result: result, warnings: warnings}
    end

    test "imports every synthetic resident", %{result: result} do
      assert result.residents == 32
      assert result.rotations > 0
    end

    test "produces no unknown-rotation warnings", %{warnings: warnings} do
      assert warnings == []
    end

    test "keeps the invented names rather than canonical ones", %{result: result} do
      names =
        result.schedule_id
        |> Residents.list_residents_for_schedule()
        |> Enum.map(& &1.name)

      {:ok, baseline, []} = @baseline_path |> File.read!() |> CsvParser.parse()
      assert Enum.sort(names) == Enum.sort(Enum.map(baseline, & &1.name))
    end

    test "covers the current academic year so it renders on the calendar" do
      assert Schedules.get_by_year!(2026).label == "2026–2027"
    end

    test "canonical names are restored once demo mode is off" do
      set_demo_mode(false)
      csv = File.read!(Release.demo_csv_path())
      {:ok, result, _warnings} = ScheduleImporter.import_csv(csv)

      names =
        result.schedule_id
        |> Residents.list_residents_for_schedule()
        |> Enum.map(& &1.name)

      refute "Wren Halloway" in names
    end

    test "re-importing replaces the demo year without duplicating residents" do
      csv = File.read!(Release.demo_csv_path())
      {:ok, second, _warnings} = ScheduleImporter.import_csv(csv)

      assert second.residents == 32
      assert length(Residents.list_residents_for_schedule(second.schedule_id)) == 32
    end

    test "the deployment seed entry point is idempotent" do
      assert {:ok, first, []} = Release.seed_demo()
      assert {:ok, second, []} = Release.seed_demo()

      assert first.residents == second.residents
      assert first.rotations == second.rotations
      assert length(Residents.list_residents_for_schedule(second.schedule_id)) == 32
      assert Schedules.get_by_year!(2026).id == second.schedule_id
    end
  end

  describe "demo schedule realism" do
    # Regenerate the fixture with `python3 priv/demo/generate_demo_schedule.py`
    # if any of these fail after editing the template it is derived from.

    # Call and absence markers legitimately repeat within a class: they say
    # where a resident is *not*, so they carry no service-capacity meaning.
    @non_rotations [:post_call, :vacation, :float]

    setup do
      {:ok, residents, []} =
        Release.demo_csv_path()
        |> File.read!()
        |> CsvParser.parse()

      %{residents: residents}
    end

    test "fields eight residents in every class", %{residents: residents} do
      counts =
        residents
        |> Enum.group_by(& &1.residency_year)
        |> Map.new(fn {year, members} -> {year, length(members)} end)

      assert counts == %{1 => 8, 2 => 8, 3 => 8, 4 => 8}

      assert Enum.sort(Enum.map(residents, & &1.position_code)) ==
               Enum.sort(for year <- 1..4, choice <- 1..8, do: "R#{year}-#{choice}")
    end

    test "preserves every fixed FLOAT assignment and the original calendar", %{
      residents: residents
    } do
      {:ok, baseline, []} = @baseline_path |> File.read!() |> CsvParser.parse()
      assert float_assignments(residents) == float_assignments(baseline)

      current_headers =
        Release.demo_csv_path() |> File.read!() |> String.split("\n") |> Enum.take(3)

      baseline_headers = @baseline_path |> File.read!() |> String.split("\n") |> Enum.take(3)
      assert current_headers == baseline_headers
    end

    test "each imported resident has two single vacation weeks and one protected double week", %{
      residents: residents
    } do
      for resident <- residents do
        vacations =
          resident.rotations
          |> Enum.filter(&(&1.rotation_type == :vacation))
          |> Enum.sort_by(& &1.start_date, Date)

        assert length(vacations) == 4, resident.position_code
        assert Enum.all?(vacations, &(Date.diff(&1.end_date, &1.start_date) == 4))

        blocks =
          vacations
          |> Enum.with_index()
          |> Enum.group_by(fn {rotation, index} ->
            Date.to_gregorian_days(rotation.start_date) - 7 * index
          end)
          |> Map.values()

        assert Enum.sort(Enum.map(blocks, &length/1)) == [1, 1, 2], resident.position_code

        [{first_week, _}, {_second_week, _}] = Enum.find(blocks, &(length(&1) == 2))

        protected_days =
          Date.range(Date.add(first_week.start_date, 5), Date.add(first_week.start_date, 6))

        projected =
          resident.rotations
          |> Enum.map(fn rotation ->
            %Rotation{
              id: rotation.slot_index,
              schedule_resident_id: resident.position_code,
              rotation_type: Atom.to_string(rotation.rotation_type),
              start_date: rotation.start_date,
              end_date: rotation.end_date
            }
          end)
          |> StrongNightBoundaries.project([], [])

        for day <- protected_days do
          refute Enum.any?(projected, fn rotation ->
                   rotation.rotation_type not in ["float", "vacation", "post_call"] and
                     Date.compare(rotation.start_date, day) != :gt and
                     Date.compare(rotation.end_date, day) != :lt
                 end),
                 resident.position_code
        end
      end
    end

    test "meets documented weekday staffing in each class and weekend staffing", %{
      residents: residents
    } do
      rotations = Enum.flat_map(residents, & &1.rotations)

      float_slots =
        rotations |> Enum.filter(&(&1.rotation_type == :float)) |> MapSet.new(& &1.slot_index)

      rotations
      |> Enum.group_by(& &1.slot_index)
      |> Enum.reject(fn {slot, _} -> MapSet.member?(float_slots, slot) end)
      |> Enum.each(fn {slot, assignments} ->
        # NF and HNF start on Sunday after import; determine the original slot
        # from any daytime assignment instead of those adjusted boundaries.
        weekend? = Enum.all?(assignments, &(Date.day_of_week(&1.start_date) in [6, 7]))

        if weekend? do
          for type <- [:strong_weekend_days, :strong_weekend_nights] do
            assert Enum.count(assignments, &(&1.rotation_type == type)) == 4,
                   "#{type} staffing at slot #{slot}"
          end
        else
          for year <- 1..4,
              type <- [
                :strong_obstetrics,
                :oncology,
                :strong_gynecology,
                :ambulatory,
                :night_float
              ] do
            count =
              residents
              |> Enum.filter(&(&1.residency_year == year))
              |> Enum.flat_map(& &1.rotations)
              |> Enum.count(&(&1.slot_index == slot and &1.rotation_type == type))

            assert count == 1, "PGY#{year} #{type} staffing at slot #{slot}"
          end

          holders =
            Enum.filter(residents, fn resident ->
              Enum.any?(
                resident.rotations,
                &(&1.slot_index == slot and &1.rotation_type == :highland_obstetrics)
              )
            end)

          assert Enum.map(holders, & &1.residency_year) == [2]
        end
      end)
    end

    test "never puts two residents of one class on the same rotation at once", %{
      residents: residents
    } do
      assert double_booked_rotations(residents) == []
    end

    test "application-projected duty has no double assignments and stays within 320 hours", %{
      residents: residents
    } do
      [start_row, end_row | _] =
        Release.demo_csv_path()
        |> File.read!()
        |> String.split("\n")
        |> Enum.take(2)
        |> Enum.map(&(String.trim_trailing(&1, "\r") |> String.split(",")))

      first = start_row |> CsvParser.parse_date_row() |> Enum.min(Date)
      last = end_row |> CsvParser.parse_date_row() |> Enum.max(Date)

      for resident <- residents do
        projected =
          resident.rotations
          |> Enum.map(fn rotation ->
            %Rotation{
              id: rotation.slot_index,
              schedule_resident_id: resident.position_code,
              rotation_type: Atom.to_string(rotation.rotation_type),
              start_date: rotation.start_date,
              end_date: rotation.end_date
            }
          end)
          |> StrongNightBoundaries.project([], [])

        work_days =
          projected
          |> Enum.reject(&(&1.rotation_type in ["float", "vacation", "post_call"]))
          |> Enum.flat_map(fn rotation ->
            Enum.map(Date.range(rotation.start_date, rotation.end_date), fn day ->
              {day, modeled_shift_hours(rotation.rotation_type)}
            end)
          end)

        assert length(work_days) == map_size(Map.new(work_days)), resident.position_code
        hours_by_day = Map.new(work_days)

        float_days =
          resident.rotations
          |> Enum.filter(&(&1.rotation_type == :float))
          |> Enum.flat_map(&Enum.to_list(Date.range(&1.start_date, &1.end_date)))
          |> MapSet.new()

        for start <- Date.range(first, Date.add(last, -27)) do
          window = Date.range(start, Date.add(start, 27))

          unless Enum.any?(window, &MapSet.member?(float_days, &1)) do
            hours = Enum.sum(Enum.map(window, &Map.get(hours_by_day, &1, 0)))
            assert hours <= 320, "#{resident.position_code} #{start}: #{hours} hours"
          end
        end
      end
    end

    test "pairs every resident with each other class at least once", %{residents: residents} do
      assert unshared_cross_class_pairs(residents) == []
    end
  end

  defp modeled_shift_hours(type) do
    if type in ~w(strong_obstetrics oncology strong_gynecology highland_obstetrics
                  highland_gynecology highland_night_float night_float strong_weekend_days
                  strong_weekend_nights highland_weekend_days highland_weekend_nights urogynecology),
      do: 12,
      else: 8
  end

  defp float_assignments(residents) do
    residents
    |> Enum.flat_map(fn resident ->
      resident.rotations
      |> Enum.filter(&(&1.rotation_type == :float))
      |> Enum.map(&{resident.position_code, &1.slot_index, &1.start_date, &1.end_date})
    end)
    |> Enum.sort()
  end

  defp double_booked_rotations(residents) do
    residents
    |> Enum.flat_map(fn resident ->
      resident.rotations
      |> Enum.reject(&(&1.rotation_type in @non_rotations))
      |> Enum.map(
        &{{resident.residency_year, &1.slot_index, &1.rotation_type}, resident.position_code}
      )
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.filter(fn {_key, codes} -> length(codes) > 1 end)
  end

  defp unshared_cross_class_pairs(residents) do
    residents
    |> pair_combinations()
    |> Enum.reject(fn {a, b} ->
      a.residency_year == b.residency_year or shares_a_rotation?(a, b)
    end)
    |> Enum.map(fn {a, b} -> {a.position_code, b.position_code} end)
  end

  defp pair_combinations([]), do: []

  defp pair_combinations([head | tail]) do
    Enum.map(tail, &{head, &1}) ++ pair_combinations(tail)
  end

  defp shares_a_rotation?(a, b) do
    a
    |> rotation_keys()
    |> MapSet.intersection(rotation_keys(b))
    |> Enum.any?()
  end

  defp rotation_keys(resident) do
    resident.rotations
    |> Enum.map(&{&1.slot_index, &1.rotation_type})
    |> MapSet.new()
  end
end
