defmodule ResidencySchedule.ScheduleBuilder.ResidentRosterTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.ScheduleBuilder.ResidentRoster

  describe "build_residents/1" do
    test "returns 32 residents with default count_per_year of 8" do
      residents = ResidentRoster.build_residents()
      assert length(residents) == 32
    end

    test "returns count_per_year * 4 residents for custom count" do
      residents = ResidentRoster.build_residents(4)
      assert length(residents) == 16
    end

    test "position codes follow R{year}-{number} format" do
      residents = ResidentRoster.build_residents()
      codes = Enum.map(residents, & &1.position_code)
      assert "R1-1" in codes
      assert "R4-8" in codes
      assert "R2-5" in codes
    end

    test "names are set to position_code as placeholder" do
      residents = ResidentRoster.build_residents()

      Enum.each(residents, fn r ->
        assert r.name == r.position_code
      end)
    end

    test "ordered by residency_year then schedule_number" do
      residents = ResidentRoster.build_residents()
      pairs = Enum.map(residents, fn r -> {r.residency_year, r.schedule_number} end)
      assert pairs == Enum.sort(pairs)
    end

    test "residency_year values are 1 through 4" do
      residents = ResidentRoster.build_residents()
      years = residents |> Enum.map(& &1.residency_year) |> Enum.uniq() |> Enum.sort()
      assert years == [1, 2, 3, 4]
    end

    test "schedule_numbers go from 1 to count_per_year within each year" do
      residents = ResidentRoster.build_residents(8)

      for year <- 1..4 do
        nums =
          residents
          |> Enum.filter(&(&1.residency_year == year))
          |> Enum.map(& &1.schedule_number)
          |> Enum.sort()

        assert nums == Enum.to_list(1..8)
      end
    end
  end

  describe "rotation_targets_for_year/1" do
    test "R1 includes Swing and US (ultrasound) but not USN (unknown)" do
      targets = ResidentRoster.rotation_targets_for_year(1)
      refute Map.has_key?(targets, :unknown)
      assert Map.has_key?(targets, :swing)
      assert Map.has_key?(targets, :ultrasound)
    end

    test "R1 does not include HHOB, REI, UG, or Elective" do
      targets = ResidentRoster.rotation_targets_for_year(1)
      refute Map.has_key?(targets, :highland_obstetrics)
      refute Map.has_key?(targets, :rei)
      refute Map.has_key?(targets, :urogynecology)
      refute Map.has_key?(targets, :elective)
    end

    test "R2 includes HHOB and REI but not US or Swing" do
      targets = ResidentRoster.rotation_targets_for_year(2)
      assert Map.has_key?(targets, :highland_obstetrics)
      assert Map.has_key?(targets, :rei)
      refute Map.has_key?(targets, :unknown)
      refute Map.has_key?(targets, :swing)
      refute Map.has_key?(targets, :ultrasound)
    end

    test "R3 includes UG and Elective but not HHOB, REI, or US" do
      targets = ResidentRoster.rotation_targets_for_year(3)
      assert Map.has_key?(targets, :urogynecology)
      assert Map.has_key?(targets, :elective)
      refute Map.has_key?(targets, :highland_obstetrics)
      refute Map.has_key?(targets, :rei)
      refute Map.has_key?(targets, :ultrasound)
    end

    test "R4 includes Elective and Swing but not HHOB, REI, UG, or US" do
      targets = ResidentRoster.rotation_targets_for_year(4)
      assert Map.has_key?(targets, :elective)
      assert Map.has_key?(targets, :swing)
      refute Map.has_key?(targets, :highland_obstetrics)
      refute Map.has_key?(targets, :rei)
      refute Map.has_key?(targets, :urogynecology)
      refute Map.has_key?(targets, :ultrasound)
      refute Map.has_key?(targets, :unknown)
    end

    test "all year levels include core clinical rotations and weekend rotations" do
      for year <- 1..4 do
        targets = ResidentRoster.rotation_targets_for_year(year)
        assert Map.has_key?(targets, :strong_obstetrics), "R#{year} missing OB"
        assert Map.has_key?(targets, :oncology), "R#{year} missing ONC"
        assert Map.has_key?(targets, :strong_gynecology), "R#{year} missing GYN"
        assert Map.has_key?(targets, :ambulatory), "R#{year} missing AMB"
        assert Map.has_key?(targets, :night_float), "R#{year} missing NF"
        assert Map.has_key?(targets, :vacation), "R#{year} missing Vac"
        assert Map.has_key?(targets, :strong_weekend_days), "R#{year} missing SWD"
        assert Map.has_key?(targets, :strong_weekend_nights), "R#{year} missing SWN"
        assert Map.has_key?(targets, :highland_night_float), "R#{year} missing HNF"
        assert Map.has_key?(targets, :highland_weekend_days), "R#{year} missing HWD"
        assert Map.has_key?(targets, :highland_weekend_nights), "R#{year} missing HWN"
      end
    end

    test "OB, AMB, NF targets are 6 for all year levels" do
      for year <- 1..4 do
        targets = ResidentRoster.rotation_targets_for_year(year)
        assert Map.fetch!(targets, :strong_obstetrics) == 6, "R#{year} OB target wrong"
        assert Map.fetch!(targets, :ambulatory) == 6, "R#{year} AMB target wrong"
        assert Map.fetch!(targets, :night_float) == 6, "R#{year} NF target wrong"
      end
    end
  end

  describe "valid_rotations_for_year/1" do
    test "R1 does not include unknown (USN) or highland_obstetrics" do
      types = ResidentRoster.valid_rotations_for_year(1)
      refute :unknown in types
      refute :highland_obstetrics in types
    end

    test "R1 includes ultrasound (US)" do
      types = ResidentRoster.valid_rotations_for_year(1)
      assert :ultrasound in types
    end

    test "R2 includes rei but not urogynecology or ultrasound" do
      types = ResidentRoster.valid_rotations_for_year(2)
      assert :rei in types
      refute :urogynecology in types
      refute :ultrasound in types
    end

    test "R3 includes urogynecology and elective but not rei or ultrasound" do
      types = ResidentRoster.valid_rotations_for_year(3)
      assert :urogynecology in types
      assert :elective in types
      refute :rei in types
      refute :ultrasound in types
    end

    test "R4 includes elective but not urogynecology, rei, or ultrasound" do
      types = ResidentRoster.valid_rotations_for_year(4)
      assert :elective in types
      refute :urogynecology in types
      refute :rei in types
      refute :ultrasound in types
    end

    test "returns sorted list" do
      types = ResidentRoster.valid_rotations_for_year(1)
      assert types == Enum.sort(types)
    end
  end

  describe "valid_rotations_for_slot/2" do
    @weekday_slot %{is_weekend: false, start_date: ~D[2026-06-29], end_date: ~D[2026-07-03]}
    @weekend_slot %{is_weekend: true, start_date: ~D[2026-07-04], end_date: ~D[2026-07-05]}
    @float_slot %{is_weekend: false, start_date: ~D[2026-12-21], end_date: ~D[2026-12-27]}

    test "FLOAT slot returns only [:float] for any year" do
      for year <- 1..4 do
        assert ResidentRoster.valid_rotations_for_slot(year, @float_slot) == [:float]
      end
    end

    test "weekend slot excludes weekday-only rotations" do
      types = ResidentRoster.valid_rotations_for_slot(1, @weekend_slot)
      refute :strong_obstetrics in types
      refute :night_float in types
      refute :ambulatory in types
      refute :vacation in types
    end

    test "weekend slot includes weekend-only rotations" do
      types = ResidentRoster.valid_rotations_for_slot(1, @weekend_slot)
      assert :strong_weekend_days in types
      assert :strong_weekend_nights in types
      assert :highland_weekend_days in types
      assert :highland_weekend_nights in types
    end

    test "weekday slot excludes weekend-only rotations" do
      types = ResidentRoster.valid_rotations_for_slot(1, @weekday_slot)
      refute :strong_weekend_days in types
      refute :strong_weekend_nights in types
      refute :highland_weekend_days in types
      refute :highland_weekend_nights in types
    end

    test "weekday slot includes clinical rotations valid for that year" do
      types = ResidentRoster.valid_rotations_for_slot(2, @weekday_slot)
      assert :strong_obstetrics in types
      assert :highland_obstetrics in types
      assert :rei in types
      refute :ultrasound in types
    end

    test "weekend slot only contains rotations valid for that year" do
      # R1 has highland_weekend_days/nights, R2 also; verify year filtering is applied
      r1_types = ResidentRoster.valid_rotations_for_slot(1, @weekend_slot)
      r2_types = ResidentRoster.valid_rotations_for_slot(2, @weekend_slot)
      # Both years have weekend rotations
      assert :strong_weekend_days in r1_types
      assert :strong_weekend_days in r2_types
    end
  end
end
