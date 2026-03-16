defmodule ResidencySchedule.IcalTest do
  use ExUnit.Case, async: true

  alias ResidencySchedule.Ical

  # ── night_shift?/1 ──────────────────────────────────────────────────────────

  describe "night_shift?/1" do
    test "returns true for all four night shift types" do
      assert Ical.night_shift?("night_float")
      assert Ical.night_shift?("strong_weekend_nights")
      assert Ical.night_shift?("highland_night_float")
      assert Ical.night_shift?("highland_weekend_nights")
    end

    test "returns false for day shift and all-day types" do
      refute Ical.night_shift?("ambulatory")
      refute Ical.night_shift?("strong_obstetrics")
      refute Ical.night_shift?("vacation")
      refute Ical.night_shift?("post_call")
      refute Ical.night_shift?("float")
    end
  end

  # ── all_day?/1 ──────────────────────────────────────────────────────────────

  describe "all_day?/1" do
    test "returns true for vacation, post_call, and float" do
      assert Ical.all_day?("vacation")
      assert Ical.all_day?("post_call")
      assert Ical.all_day?("float")
    end

    test "returns false for timed shift types" do
      refute Ical.all_day?("ambulatory")
      refute Ical.all_day?("night_float")
      refute Ical.all_day?("strong_obstetrics")
    end
  end

  # ── trim_last_day?/2 ────────────────────────────────────────────────────────

  describe "trim_last_day?/2" do
    test "true when next rotation is a night shift starting the following day" do
      rotation = %{end_date: ~D[2026-03-06], rotation_type: "ambulatory"}
      next = %{start_date: ~D[2026-03-07], rotation_type: "night_float"}
      assert Ical.trim_last_day?(rotation, next)
    end

    test "true for an all-day type immediately preceding a night shift" do
      rotation = %{end_date: ~D[2026-03-13], rotation_type: "post_call"}
      next = %{start_date: ~D[2026-03-14], rotation_type: "night_float"}
      assert Ical.trim_last_day?(rotation, next)
    end

    test "false when next rotation is a day shift" do
      rotation = %{end_date: ~D[2026-03-06], rotation_type: "ambulatory"}
      next = %{start_date: ~D[2026-03-07], rotation_type: "ambulatory"}
      refute Ical.trim_last_day?(rotation, next)
    end

    test "false when there is no next rotation" do
      rotation = %{end_date: ~D[2026-03-06], rotation_type: "ambulatory"}
      refute Ical.trim_last_day?(rotation, nil)
    end

    test "false when the gap between rotations is more than one day" do
      rotation = %{end_date: ~D[2026-03-06], rotation_type: "ambulatory"}
      next = %{start_date: ~D[2026-03-08], rotation_type: "night_float"}
      refute Ical.trim_last_day?(rotation, next)
    end

    test "false when the current rotation itself is a night shift" do
      rotation = %{end_date: ~D[2026-03-06], rotation_type: "night_float"}
      next = %{start_date: ~D[2026-03-07], rotation_type: "night_float"}
      refute Ical.trim_last_day?(rotation, next)
    end
  end

  # ── event_times/2 ───────────────────────────────────────────────────────────

  describe "event_times/2" do
    test "night shift starts at 6pm the day before" do
      {dtstart, _} = Ical.event_times("night_float", ~D[2026-03-09])
      assert dtstart == "20260308T180000"
    end

    test "night shift ends at 6am on the listed date" do
      {_, dtend} = Ical.event_times("night_float", ~D[2026-03-09])
      assert dtend == "20260309T060000"
    end

    test "day shift starts at 6am and ends at 6pm" do
      assert Ical.event_times("ambulatory", ~D[2026-03-09]) ==
               {"20260309T060000", "20260309T180000"}
    end

    test "night shift handles month boundary correctly" do
      {dtstart, dtend} = Ical.event_times("night_float", ~D[2026-03-01])
      assert dtstart == "20260228T180000"
      assert dtend == "20260301T060000"
    end

    test "night shift handles year boundary correctly" do
      {dtstart, dtend} = Ical.event_times("strong_weekend_nights", ~D[2027-01-01])
      assert dtstart == "20261231T180000"
      assert dtend == "20270101T060000"
    end
  end

  # ── build/1 ─────────────────────────────────────────────────────────────────

  describe "build/1" do
    test "produces a valid VCALENDAR structure" do
      resident = %{name: "Test", rotations: []}
      result = Ical.build(resident)
      assert result =~ "BEGIN:VCALENDAR"
      assert result =~ "END:VCALENDAR"
    end

    test "night shift block generates per-day 6pm→6am events" do
      rotation = %{id: 1, rotation_type: "night_float", start_date: ~D[2026-03-09], end_date: ~D[2026-03-10]}
      result = Ical.build(%{name: "Test", rotations: [rotation]})
      assert result =~ "DTSTART:20260308T180000"
      assert result =~ "DTEND:20260309T060000"
      assert result =~ "DTSTART:20260309T180000"
      assert result =~ "DTEND:20260310T060000"
    end

    test "day shift block generates per-day 6am→6pm events" do
      rotation = %{id: 1, rotation_type: "ambulatory", start_date: ~D[2026-03-02], end_date: ~D[2026-03-03]}
      result = Ical.build(%{name: "Test", rotations: [rotation]})
      assert result =~ "DTSTART:20260302T060000"
      assert result =~ "DTEND:20260302T180000"
      assert result =~ "DTSTART:20260303T060000"
      assert result =~ "DTEND:20260303T180000"
    end

    test "vacation generates a single all-day event spanning the full block" do
      vac = %{id: 1, rotation_type: "vacation", start_date: ~D[2026-03-09], end_date: ~D[2026-03-15]}
      result = Ical.build(%{name: "Test", rotations: [vac]})
      assert result =~ "DTSTART;VALUE=DATE:20260309"
      assert result =~ "DTEND;VALUE=DATE:20260316"
      # Only one VEVENT (not per-day)
      assert length(Regex.scan(~r/BEGIN:VEVENT/, result)) == 1
    end

    test "post_call generates a single all-day event" do
      pc = %{id: 1, rotation_type: "post_call", start_date: ~D[2026-03-14], end_date: ~D[2026-03-15]}
      result = Ical.build(%{name: "Test", rotations: [pc]})
      assert result =~ "DTSTART;VALUE=DATE:20260314"
      assert result =~ "DTEND;VALUE=DATE:20260316"
    end

    test "float generates a single all-day event" do
      fl = %{id: 1, rotation_type: "float", start_date: ~D[2026-03-02], end_date: ~D[2026-03-06]}
      result = Ical.build(%{name: "Test", rotations: [fl]})
      assert result =~ "DTSTART;VALUE=DATE:20260302"
      assert result =~ "DTEND;VALUE=DATE:20260307"
    end

    test "last day of day-shift block trimmed when immediately followed by night shift" do
      amb = %{id: 1, rotation_type: "ambulatory", start_date: ~D[2026-02-23], end_date: ~D[2026-02-27]}
      swn = %{id: 2, rotation_type: "strong_weekend_nights", start_date: ~D[2026-02-28], end_date: ~D[2026-03-01]}
      result = Ical.build(%{name: "Test", rotations: [amb, swn]})
      assert result =~ "DTSTART:20260226T060000"
      refute result =~ "DTSTART:20260227T060000"
      assert result =~ "DTSTART:20260227T180000"
    end

    test "all-day block trimmed when immediately followed by night shift" do
      pc = %{id: 1, rotation_type: "post_call", start_date: ~D[2026-03-14], end_date: ~D[2026-03-15]}
      nf = %{id: 2, rotation_type: "night_float", start_date: ~D[2026-03-16], end_date: ~D[2026-03-20]}
      result = Ical.build(%{name: "Test", rotations: [pc, nf]})
      # DTEND should be 03-15 (exclusive), meaning only 03-14 is shown
      assert result =~ "DTSTART;VALUE=DATE:20260314"
      assert result =~ "DTEND;VALUE=DATE:20260315"
    end

    test "last day NOT trimmed when next shift is a day shift" do
      amb1 = %{id: 1, rotation_type: "ambulatory", start_date: ~D[2026-03-02], end_date: ~D[2026-03-06]}
      amb2 = %{id: 2, rotation_type: "ambulatory", start_date: ~D[2026-03-07], end_date: ~D[2026-03-08]}
      result = Ical.build(%{name: "Test", rotations: [amb1, amb2]})
      assert result =~ "DTSTART:20260306T060000"
    end

    test "last day NOT trimmed when there is a gap before the night shift" do
      amb = %{id: 1, rotation_type: "ambulatory", start_date: ~D[2026-03-02], end_date: ~D[2026-03-06]}
      nf = %{id: 2, rotation_type: "night_float", start_date: ~D[2026-03-08], end_date: ~D[2026-03-10]}
      result = Ical.build(%{name: "Test", rotations: [amb, nf]})
      assert result =~ "DTSTART:20260306T060000"
    end
  end
end
