defmodule ResidencySchedule.RotationSupportTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Assistant.RotationAliases
  alias ResidencySchedule.Ical
  alias ResidencySchedule.Importer.CsvParser
  alias ResidencySchedule.Rotations
  alias ResidencySchedule.RotationSupportFixtures, as: Fixtures
  alias ResidencySchedule.ScheduleBuilder.{Coverage, DutyHours, ResidentRoster}

  for {label, type} <- Fixtures.pairs() do
    @label label
    @rotation_type type

    test "imports #{@label} case-insensitively in ordinary and date-update uploads" do
      for label <- [@label, String.downcase(@label), String.upcase(@label), " #{@label} "] do
        csv = Fixtures.csv([label])
        assert {:ok, [resident], []} = CsvParser.parse(csv)

        assert [
                 %{
                   rotation_type: @rotation_type,
                   start_date: ~D[2026-07-06],
                   end_date: ~D[2026-07-06]
                 }
               ] =
                 resident.rotations

        assert {:ok, [updated], []} = CsvParser.parse_date_update(csv, 2026)
        assert [%{rotation_type: @rotation_type}] = updated.rotations
      end
    end

    test "registers #{@label} with display label, color and assistant alias" do
      type = Atom.to_string(@rotation_type)
      assert type in Rotations.all_rotation_types()
      refute Rotations.rotation_type_label(type) in [type, "Unknown"]
      refute Rotations.rotation_type_color(type) == "bg-gray-200 text-gray-600"
      assert {:ok, ^type} = RotationAliases.resolve(@label)
      assert {:ok, ^type} = RotationAliases.resolve(type)
      assert RotationAliases.weekend_counterparts(type) == []
      refute Map.has_key?(Coverage.required_coverage(), @rotation_type)

      for year <- 1..4,
          do: refute(Map.has_key?(ResidentRoster.rotation_targets_for_year(year), @rotation_type))
    end
  end

  test "strips only trailing till-8p annotations while preserving the clinical shift" do
    pairs = [
      {"GYN - till 8p", :strong_gynecology},
      {"OB - till 8p", :strong_obstetrics},
      {"HGYN - till 8p", :highland_gynecology}
    ]

    for {label, type} <- pairs, value <- [label, String.upcase(label), " #{label} "] do
      assert {:ok, [resident], []} = CsvParser.parse(Fixtures.csv([value]))
      assert [%{rotation_type: ^type}] = resident.rotations
      assert {:ok, [updated], []} = CsvParser.parse_date_update(Fixtures.csv([value]), 2026)
      assert [%{rotation_type: ^type}] = updated.rotations
    end

    for value <- ["UNRECOGNIZED - till 8p", "OB - till 9p", "OB - till 8p extra"] do
      assert {:ok, [resident], [_]} = CsvParser.parse(Fixtures.csv([value]))
      assert resident.rotations == []
      assert {:ok, [updated], [_]} = CsvParser.parse_date_update(Fixtures.csv([value]), 2026)
      assert updated.date_updates == []
    end
  end

  test "date update still treats OFF as an explicit empty assignment" do
    assert {:ok, [resident], []} = CsvParser.parse_date_update(Fixtures.csv(["OFF"]), 2026)
    assert [%{rotation: nil}] = resident.date_updates
  end

  test "leave of absence is non-working; admin, clinics and orientation are working solo assignments" do
    refute Rotations.working_day?("leave_of_absence")
    refute Rotations.shared_service?("leave_of_absence")
    assert "leave_of_absence" in Rotations.non_working_rotation_types()

    for {_, type} <- Fixtures.pairs(), type != :leave_of_absence do
      type = Atom.to_string(type)
      assert Rotations.working_day?(type)
      refute Rotations.shared_service?(type)
      assert type in Rotations.solo_rotation_types()
    end
  end

  test "manual builder choices respect admin and orientation year restrictions without adding quotas" do
    general = ~w(leave_of_absence cob gog_colpo mfm mfm_pain mfm_pm orientation)a

    counterparts = [
      oncology_orientation: :oncology,
      highland_obstetrics_orientation: :highland_obstetrics,
      strong_gynecology_orientation: :strong_gynecology,
      highland_gynecology_orientation: :highland_gynecology,
      strong_obstetrics_orientation: :strong_obstetrics
    ]

    slot = %{is_weekend: false, start_date: ~D[2026-07-06], end_date: ~D[2026-07-10]}

    for year <- 1..4 do
      choices = ResidentRoster.valid_rotations_for_year(year)
      for type <- general, do: assert(type in choices)
      for type <- [:admin, :admin_mfm], do: assert(Enum.member?(choices, type) == (year == 4))

      for {orientation, counterpart} <- counterparts,
          do: assert(Enum.member?(choices, orientation) == Enum.member?(choices, counterpart))

      for type <- choices,
          type in Enum.map(Fixtures.pairs(), &elem(&1, 1)),
          do: assert(type in ResidentRoster.valid_rotations_for_slot(year, slot))
    end
  end

  test "SCN remains unsupported because it belongs to fellows" do
    refute "scn" in Rotations.all_rotation_types()
    assert {:ok, [resident], [{"R4-1", 0, "SCN"}]} = CsvParser.parse(Fixtures.csv(["SCN"]))
    assert resident.rotations == []
    assert {:error, :unknown_rotation} = RotationAliases.resolve("SCN")
    for year <- 1..4, do: refute(:scn in ResidentRoster.valid_rotations_for_year(year))
  end

  test "duty hours distinguish admin, clinics and clinical orientations for atoms and stored strings" do
    for {type, hours} <- [
          admin: 0,
          admin_mfm: 6,
          leave_of_absence: 0,
          cob: 9,
          gog_colpo: 9,
          mfm: 9,
          mfm_pain: 9,
          mfm_pm: 9,
          orientation: 9,
          oncology_orientation: 12,
          highland_obstetrics_orientation: 12,
          strong_gynecology_orientation: 12,
          highland_gynecology_orientation: 12,
          strong_obstetrics_orientation: 12
        ] do
      assert DutyHours.hours_for_rotation(type) == hours
      assert DutyHours.hours_for_rotation(Atom.to_string(type)) == hours
    end
  end

  test "MFM PM names perimenopausal clinic rather than an afternoon shift" do
    assert Rotations.rotation_type_label("mfm_pm") == "MFM Perimenopausal Clinic"
  end

  test "clinics retain distinct canonical identities and bare GOG means GOG/Colpo" do
    assert {:ok, [resident], []} =
             CsvParser.parse(Fixtures.csv(["COB", "GOG/Colpo", "MFM", "MFM/pain", "MFM PM"]))

    assert Enum.map(resident.rotations, & &1.rotation_type) == [
             :cob,
             :gog_colpo,
             :mfm,
             :mfm_pain,
             :mfm_pm
           ]

    assert {:ok, "gog_colpo"} = RotationAliases.resolve("GOG")
  end

  test "clinics, admin and orientation cannot be selected for weekend or FLOAT slots" do
    weekend = %{is_weekend: true, start_date: ~D[2026-07-11], end_date: ~D[2026-07-12]}
    float = %{is_weekend: false, start_date: ~D[2026-12-21], end_date: ~D[2026-12-27]}

    for year <- 1..4 do
      assert :leave_of_absence in ResidentRoster.valid_rotations_for_slot(year, weekend)

      for {_, type} <- Fixtures.pairs(), type != :leave_of_absence do
        refute type in ResidentRoster.valid_rotations_for_slot(year, weekend)
      end

      assert ResidentRoster.valid_rotations_for_slot(year, float) == [:float]
    end
  end

  test "iCalendar exposes human labels and leave of absence as an all-day absence" do
    for {_, type} <- Fixtures.pairs() do
      type = Atom.to_string(type)

      calendar =
        Ical.build_from_segments(
          [%{rotation_type: type, start_date: ~D[2026-07-06], end_date: ~D[2026-07-06]}],
          "Test Resident"
        )

      assert calendar =~ "SUMMARY:#{Rotations.rotation_type_label(type)}\n"
      refute calendar =~ "SUMMARY:#{type}\n"
    end

    assert Ical.all_day?("leave_of_absence")

    calendar =
      Ical.build_from_segments(
        [
          %{
            rotation_type: "leave_of_absence",
            start_date: ~D[2026-07-06],
            end_date: ~D[2026-07-08]
          }
        ],
        "Test Resident"
      )

    assert calendar =~ "DTSTART;VALUE=DATE:20260706"
    assert calendar =~ "DTEND;VALUE=DATE:20260709"
    assert length(Regex.scan(~r/BEGIN:VEVENT/, calendar)) == 1
  end
end
