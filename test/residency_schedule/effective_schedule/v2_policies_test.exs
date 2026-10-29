defmodule ResidencySchedule.EffectiveSchedule.V2PoliciesTest do
  use ResidencySchedule.DataCase, async: true

  alias ResidencySchedule.{EffectiveSchedule, Repo, ShiftOverrides}
  alias ResidencySchedule.EffectiveScheduleV2Fixtures, as: F

  test "night_boundary shifts canonical Strong nights and preserves unsplit calendar identities" do
    member = F.member()
    F.rotation(member, "night_float", ~D[2026-11-02], ~D[2026-11-06])
    F.rotation(member, "post_call", ~D[2026-11-07], ~D[2026-11-08], 1)

    for date <- Date.range(~D[2026-11-01], ~D[2026-11-05]) do
      assert [%{code: "night_float", source_assignment_date: ~D[2026-11-01]}] =
               duties(member, date)
    end

    assert [%{code: "post_call"}] = duties(member, ~D[2026-11-06])
    assert [%{code: "post_call"}] = duties(member, ~D[2026-11-07])
    assert events(member, :v2) == events(member, :legacy)

    assert Enum.any?(
             events(member, :v2),
             &(&1.uid == "seg-night_float-2026-11-01-2026-11-03@residency-schedule")
           )
  end

  test "night_boundary preserves an explicit Friday using retained target evidence after relabeling" do
    member = F.member()
    F.rotation(member, "night_float", ~D[2026-11-02], ~D[2026-11-06])
    source = F.source(member, ~D[2026-11-06], "SMH Obstetrics Resident 1st Contact Night")
    F.retain([source])
    Repo.update!(Ecto.Changeset.change(source.activity, raw_task: "Renamed Friday duty"))

    assert Enum.any?(duties(member, ~D[2026-11-06]), &(&1.code == "night_float"))
    refute Enum.any?(duties(member, ~D[2026-11-06]), &(&1.code == "post_call"))

    assert Enum.any?(
             events(member, :v2),
             &(&1.dtstart == "20261106T180000" and &1.dtend == "20261107T060000")
           )
  end

  test "coverage_precedence preserves protected Friday type and source-date boundary calendar UIDs" do
    owner = F.member()
    cover = F.member(2026, 2)
    night = F.rotation(owner, "night_float", ~D[2026-11-02], ~D[2026-11-06])
    F.rotation(cover, "elective", ~D[2026-11-05], ~D[2026-11-06])
    override(night, cover, ~D[2026-11-05], ~D[2026-11-06])

    for date <- [~D[2026-11-05], ~D[2026-11-06]] do
      assert [%{code: "night_float", status: :covered, covered_by_person_id: covered_by}] =
               duties(owner, date)

      assert covered_by == cover.resident_id

      assert [%{kind: :coverage, code: "night_float", original_person_id: original}] =
               duties(cover, date)

      assert original == owner.resident_id
    end

    assert events(cover, :v2) == events(cover, :legacy)

    assert Enum.map(events(cover, :v2), & &1.uid) == [
             "seg-night_float-2026-11-05-2026-11-05@residency-schedule",
             "seg-night_float-2026-11-05-2026-11-06@residency-schedule"
           ]
  end

  test "Highland post-call normalization removes only the owner's overlapping night dates" do
    member = F.member()
    F.rotation(member, "post_call", ~D[2026-11-07], ~D[2026-11-08])
    F.rotation(member, "highland_night_float", ~D[2026-11-08], ~D[2026-11-13], 1)
    assert [%{code: "post_call"}] = duties(member, ~D[2026-11-07])
    assert [%{code: "highland_night_float"}] = duties(member, ~D[2026-11-08])
    assert events(member, :v2) == events(member, :legacy)
  end

  test "saturday_highland_gap uses retained context targets and weekday, not the label" do
    member = F.member()
    saturday = F.source(member, ~D[2026-11-07], "HH Nights 3rd Call")
    sunday = F.source(member, ~D[2026-11-08], "HH Nights 3rd Call")
    F.retain([saturday, sunday])

    for source <- [saturday, sunday],
        do:
          Repo.update!(Ecto.Changeset.change(source.activity, raw_task: "Renamed Highland duty"))

    assert [%{kind: :gap_fill, code: "highland_weekend_nights"}] = duties(member, ~D[2026-11-07])
    assert [%{kind: :gap_fill, code: "qgenda_assignment"}] = duties(member, ~D[2026-11-08])
    assert {:ok, diagnostics} = EffectiveSchedule.evidence_diagnostics(member.schedule_id, :v2)
    assert diagnostics == [F.diagnostic(sunday, :context_required)]
  end

  test "context-required evidence resolves from the day's base service" do
    member = F.member()
    F.rotation(member, "highland_night_float", ~D[2026-11-08], ~D[2026-11-08])
    source = F.source(member, ~D[2026-11-08], "HH Nights 3rd Call")
    F.retain([source])
    assert Enum.all?(duties(member, ~D[2026-11-08]), &(&1.code == "highland_night_float"))
    assert duties(member, ~D[2026-11-08]) != []
    assert EffectiveSchedule.evidence_diagnostics(member.schedule_id, :v2) == {:ok, []}
  end

  test "gap_fill resolves retained unique types but never promotes recognition to a service" do
    member = F.member()
    ultrasound = F.source(member, ~D[2026-11-03], "Ultrasound")
    recognized = F.source(member, ~D[2026-11-04], "GOG Continuity Clinic AM", "AM")
    unknown = F.source(member, ~D[2026-11-05], "Unknown synthetic duty")
    F.retain([ultrasound, recognized, unknown])

    assert [%{kind: :gap_fill, code: "ultrasound"}] = duties(member, ~D[2026-11-03])

    assert [
             %{
               kind: :gap_fill,
               code: "qgenda_assignment",
               source_tasks: ["GOG Continuity Clinic AM"]
             }
           ] = duties(member, ~D[2026-11-04])

    assert [%{code: "qgenda_assignment", label: "Unknown synthetic duty"}] =
             duties(member, ~D[2026-11-05])

    assert {:ok, diagnostics} = EffectiveSchedule.evidence_diagnostics(member.schedule_id, :v2)
    assert F.diagnostic(unknown, :unmapped_classification) in diagnostics
  end

  test "cross-schedule coverage wins over gaps and own duties without hiding neighboring activities" do
    owner = F.member()
    cover = F.member(2027, 2)
    block = F.rotation(owner, "strong_obstetrics", ~D[2026-11-02], ~D[2026-11-06])
    F.rotation(cover, "elective", ~D[2026-11-05], ~D[2026-11-05])
    inside = F.source(cover, ~D[2026-11-03], "Ultrasound")
    outside = F.source(cover, ~D[2026-11-04], "Ultrasound")
    F.retain([inside, outside])
    override(block, cover, ~D[2026-11-03], ~D[2026-11-03])
    override(block, cover, ~D[2026-11-05], ~D[2026-11-05])

    for date <- [~D[2026-11-03], ~D[2026-11-05]] do
      assert [%{kind: :coverage, code: "strong_obstetrics", original_person_id: original}] =
               duties(cover, date)

      assert original == owner.resident_id
    end

    assert [%{kind: :gap_fill, code: "ultrasound"}] = duties(cover, ~D[2026-11-04])
    assert {:ok, records} = EffectiveSchedule.for_person(cover.resident_id, :v2)
    assert {:ok, ^records} = EffectiveSchedule.for_schedule(cover.schedule_id, :v2)
  end

  test "legacy Friday evidence without a trigger policy diagnoses instead of guessing from labels" do
    member = F.member()
    F.rotation(member, "ambulatory", ~D[2026-11-02], ~D[2026-11-06])
    source = F.source(member, ~D[2026-11-06], "SMH Obstetrics Resident 1st Contact Night")
    F.retain_historical_contact(source)
    before = duties(member, ~D[2026-11-06])
    assert Enum.any?(before, &(&1.code == "ambulatory" and &1.kind == :rotation))
    refute Enum.any?(before, &(&1.code == "strong_weekend_nights"))
    assert {:ok, diagnostics} = EffectiveSchedule.evidence_diagnostics(member.schedule_id, :v2)
    assert F.diagnostic(source, :insufficient_policy_evidence) in diagnostics

    Repo.update!(
      Ecto.Changeset.change(source.activity, raw_task: "SMH Gynecology Chief On Call Night")
    )

    after_relabel = duties(member, ~D[2026-11-06])

    assert Enum.map(after_relabel, &{&1.kind, &1.code, &1.status}) ==
             Enum.map(before, &{&1.kind, &1.code, &1.status})
  end

  test "friday_strong_correction uses enriched evidence once and survives label changes" do
    contact = F.member()
    usual_night = F.member(2026, 2)
    F.rotation(contact, "ambulatory", ~D[2026-11-09], ~D[2026-11-13])
    F.rotation(usual_night, "night_float", ~D[2026-11-13], ~D[2026-11-13])
    source = F.source(contact, ~D[2026-11-13], "SMH Obstetrics Resident 1st Contact Night")
    duplicate = F.add_source(contact, source.activity)
    F.retain([source, duplicate])
    Repo.update!(Ecto.Changeset.change(source.activity, raw_task: "Opaque renamed Friday"))

    assert [%{code: "strong_weekend_nights", source_assignment_date: ~D[2026-11-13]}] =
             duties(contact, ~D[2026-11-13])

    assert [%{code: "post_call"}] = duties(usual_night, ~D[2026-11-13])
    assert [%{code: "ambulatory"}] = duties(contact, ~D[2026-11-12])
    assert Enum.count(events(contact, :v2), &(&1.dtstart == "20261113T180000")) == 1
    refute Enum.any?(events(contact, :v2), &(&1.dtstart == "20261112T180000"))
    assert EffectiveSchedule.evidence_diagnostics(contact.schedule_id, :v2) == {:ok, []}
  end

  test "Friday correction does not trigger from generic gynecology evidence relabeled as contact" do
    member = F.member()
    F.rotation(member, "ambulatory", ~D[2026-11-09], ~D[2026-11-13])
    source = F.source(member, ~D[2026-11-13], "SMH Gynecology Chief On Call Night")
    F.retain([source])

    Repo.update!(
      Ecto.Changeset.change(source.activity,
        raw_task: "SMH Obstetrics Resident 1st Contact Night"
      )
    )

    assert Enum.any?(duties(member, ~D[2026-11-13]), &(&1.code == "ambulatory"))
    refute Enum.any?(duties(member, ~D[2026-11-13]), &(&1.code == "strong_weekend_nights"))
    assert {:ok, diagnostics} = EffectiveSchedule.evidence_diagnostics(member.schedule_id, :v2)
    assert F.diagnostic(source, :insufficient_policy_evidence) in diagnostics
  end

  test "Friday correction respects approved coverage and explicit usual-team night evidence" do
    contact = F.member()
    usual_night = F.member(2026, 2)
    cover = F.member(2026, 3)
    amb = F.rotation(contact, "ambulatory", ~D[2026-11-09], ~D[2026-11-13])
    F.rotation(usual_night, "night_float", ~D[2026-11-13], ~D[2026-11-13])

    contact_source =
      F.source(contact, ~D[2026-11-13], "SMH Obstetrics Resident 1st Contact Night")

    explicit = F.source(usual_night, ~D[2026-11-13], "SMH Gynecology Chief On Call Night")
    F.retain([contact_source, explicit])
    # Explicit usual-team evidence wins while a real contact trigger exists.
    assert [%{code: "strong_weekend_nights"}] = duties(contact, ~D[2026-11-13])
    assert Enum.any?(duties(usual_night, ~D[2026-11-13]), &(&1.code == "night_float"))
    refute Enum.any?(duties(usual_night, ~D[2026-11-13]), &(&1.code == "post_call"))
    override(amb, cover, ~D[2026-11-13], ~D[2026-11-13])

    assert Enum.any?(
             duties(contact, ~D[2026-11-13]),
             &(&1.code == "ambulatory" and &1.status == :covered)
           )

    assert [%{kind: :coverage, code: "ambulatory"}] = duties(cover, ~D[2026-11-13])
    refute Enum.any?(duties(contact, ~D[2026-11-13]), &(&1.code == "strong_weekend_nights"))
    assert Enum.any?(duties(usual_night, ~D[2026-11-13]), &(&1.code == "night_float"))
    refute Enum.any?(duties(usual_night, ~D[2026-11-13]), &(&1.code == "post_call"))
  end

  defp duties(member, date) do
    {:ok, records} = EffectiveSchedule.for_date(member.schedule_id, date, :v2)
    Enum.find(records, &(&1.schedule_resident_id == member.id)).duties
  end

  defp events(member, version) do
    {:ok, events} = EffectiveSchedule.calendar_events(member.resident_id, version)
    events
  end

  defp override(rotation, cover, first, last) do
    {:ok, override} =
      ShiftOverrides.create_override(%{
        rotation_id: rotation.id,
        covering_schedule_resident_id: cover.id,
        override_start_date: first,
        override_end_date: last
      })

    override
  end
end
