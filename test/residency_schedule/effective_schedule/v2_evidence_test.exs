defmodule ResidencySchedule.EffectiveSchedule.V2EvidenceTest do
  use ResidencySchedule.DataCase, async: true

  import Ecto.Query

  alias ResidencySchedule.DetailedSchedules.{Activity, ActivitySource}
  alias ResidencySchedule.EffectiveSchedule
  alias ResidencySchedule.EffectiveSchedule.Comparison
  alias ResidencySchedule.EffectiveScheduleV2Fixtures, as: F
  alias ResidencySchedule.IdentityMappings.Mapping
  alias ResidencySchedule.Repo
  alias ResidencySchedule.TaskMappings.Classification
  alias ResidencySchedule.Timings.Timing

  doctest ResidencySchedule.EffectiveScheduleV2Fixtures

  @date ~D[2026-11-03]
  @date_only %{precision: :date_only, period: nil}

  test "resolved occurrence meaning is retained evidence, not its current raw label" do
    member = F.member()
    source = F.source(member, @date, "Ultrasound")
    F.retain([source])
    Repo.update!(Ecto.Changeset.change(source.activity, raw_task: "Renamed opaque label"))

    assert [%{code: "ultrasound", kind: :gap_fill, timing: @date_only} = duty] = duties(member)
    assert duty.source_tasks == ["Renamed opaque label"]
    assert diagnostics(member) == []
  end

  test "an independent clinic remains simultaneous with a rotation and retains period precision" do
    member = F.member()
    F.rotation(member, "ambulatory", @date, @date)
    source = F.source(member, @date, "GOG Continuity Clinic AM", "AM")
    F.retain([source])

    assert [activity, rotation] = duties(member)
    assert activity.kind == :dated_activity
    assert activity.code == "qgenda_assignment"
    assert activity.source_tasks == ["GOG Continuity Clinic AM"]
    assert activity.timing == %{precision: :period, period: "AM"}
    assert rotation.kind == :rotation
    assert rotation.code == "ambulatory"
    assert rotation.timing == @date_only
  end

  test "same-code period and exact facts remain independent of a base rotation" do
    member = F.member()
    F.rotation(member, "ultrasound", @date, @date)
    period = F.source(member, @date, "Ultrasound", "AM")
    duplicate = F.add_source(member, period.activity)
    exact = F.add_source(member, period.activity)
    F.retain([period, duplicate, exact])

    F.timing(exact)
    |> Ecto.Changeset.change(
      precision: "exact",
      period: nil,
      starts_at: ~U[2026-11-03 14:15:00Z],
      ends_at: ~U[2026-11-03 15:45:00Z],
      time_zone: "Etc/UTC",
      policy: "exact_source",
      evidence_origin: "reviewed"
    )
    |> Repo.update!()

    result = duties(member)
    assert length(result) == 3
    assert Enum.all?(result, &(&1.code == "ultrasound"))
    assert [%{timing: @date_only}] = Enum.filter(result, &(&1.kind == :rotation))
    activities = Enum.filter(result, &(&1.kind == :dated_activity))
    assert length(activities) == 2
    assert Enum.count(activities, &(&1.timing == %{precision: :period, period: "AM"})) == 1
    assert Enum.count(activities, &(&1.timing.precision == :exact)) == 1
    assert diagnostics(member) == []

    assert {:ok, legacy_events} = EffectiveSchedule.calendar_events(member.resident_id, :legacy)
    assert {:ok, events} = EffectiveSchedule.calendar_events(member.resident_id, :v2)
    base_uid = "seg-ultrasound-2026-11-03-2026-11-03@residency-schedule"

    assert Enum.find(events, &(&1.uid == base_uid)) ==
             Enum.find(legacy_events, &(&1.uid == base_uid))

    assert Enum.any?(events, &(&1.uid == base_uid))
    assert [timed] = Enum.filter(events, &(&1.dtstart == "20261103T141500Z"))
    assert timed.dtend == "20261103T154500Z"
    refute timed.uid == base_uid
    assert length(Enum.uniq_by(events, & &1.uid)) == length(events)
    assert EffectiveSchedule.calendar_events(member.resident_id, :v2) == {:ok, events}
  end

  test "OFF stays a visible unmapped assignment without invented off semantics" do
    member = F.member()
    source = F.source(member, @date, "OFF")
    F.retain([source])
    assert %{off: nil, duties: [duty]} = record(member)
    assert duty.code == "qgenda_assignment"
    assert duty.label == "OFF"
    assert duty.status == :working
    assert duty.timing == @date_only
    assert diagnostics(member) == [F.diagnostic(source, :unmapped_classification)]
  end

  test "missing classifications and timings do not trigger runtime backfills or label inference" do
    member = F.member()
    source = F.source(member, @date, "Vacation", "PM")
    F.retain([source])
    Repo.delete!(F.classification(source))
    Repo.delete!(F.timing(source))
    before = evidence_snapshot()

    assert [%{code: "qgenda_assignment", status: :working, timing: @date_only}] = duties(member)

    assert Enum.sort(diagnostics(member)) ==
             Enum.sort([
               F.diagnostic(source, :missing_classification),
               F.diagnostic(source, :missing_timing)
             ])

    assert {:ok, _} = EffectiveSchedule.calendar_events(member.resident_id, :v2)
    assert {:ok, _} = Comparison.run(member.schedule_id)
    assert evidence_snapshot() == before
  end

  test "missing identity retains original membership and reports it without exact-name fallback" do
    member = F.member()
    source = F.source(member, @date, "Ultrasound")
    F.retain([source])
    Repo.delete_all(Mapping)
    Repo.update!(Ecto.Changeset.change(source.source, raw_staff: member.name))

    assert [%{code: "ultrasound"}] = duties(member)
    assert diagnostics(member) == [F.diagnostic(source, :missing_identity)]
  end

  test "held identity excludes source duty while preserving the base rotation" do
    member = F.member()
    F.rotation(member, "ambulatory", @date, @date)
    source = F.source(member, @date, "Ultrasound")
    F.retain([source])
    Mapping |> where([m], m.status == "approved") |> Repo.delete_all()

    assert [%{kind: :rotation, code: "ambulatory"}] = duties(member)
    assert diagnostics(member) == [F.diagnostic(source, :held_identity)]
  end

  test "diagnostics survive a held-identity schedule with no accepted duties" do
    member = F.member()
    source = F.source(member, @date, "Ultrasound")
    F.retain([source])
    Mapping |> where([m], m.status == "approved") |> Repo.delete_all()

    assert EffectiveSchedule.for_schedule(member.schedule_id, :v2) == {:ok, []}
    assert diagnostics(member) == [F.diagnostic(source, :held_identity)]
    assert {:ok, summary} = Comparison.run(member.schedule_id)
    assert summary.unresolved_evidence == 1
    assert summary.detail.evidence == [F.diagnostic(source, :held_identity)]
  end

  test "comparison retains prior-year calendar events when current held evidence has no duties" do
    member = F.member()
    prior = F.member(2025)
    assert prior.resident_id == member.resident_id
    F.rotation(prior, "ambulatory", ~D[2025-11-03], ~D[2025-11-03])
    source = F.source(member, @date, "Ultrasound")
    F.retain([source])
    Mapping |> where([m], m.status == "approved") |> Repo.delete_all()

    assert EffectiveSchedule.for_schedule(member.schedule_id, :v2) == {:ok, []}
    assert {:ok, [prior_event]} = EffectiveSchedule.calendar_events(member.resident_id, :v2)
    assert prior_event.dtstart == "20251103T060000"
    assert {:ok, summary} = Comparison.run(member.schedule_id)
    assert summary.unresolved_evidence == 1
    assert summary.detail.evidence == [F.diagnostic(source, :held_identity)]
    assert summary.differing_calendar_events == 1
    assert [%{person_id: person_id, legacy: removed, v2: nil}] = summary.detail.calendar_events
    assert person_id == member.resident_id
    assert removed.dtstart == "20261103T060000"
    refute removed.uid == prior_event.uid
  end

  test "conflicting approved identity cannot reassign an occurrence to a different member" do
    member = F.member()
    other = F.member(2026, 2)
    F.rotation(member, "ambulatory", @date, @date)
    source = F.source(member, @date, "Ultrasound")
    F.retain([source])
    approved = Repo.one!(from(m in Mapping, where: m.status == "approved"))

    snapshot =
      Map.merge(approved.target_snapshot, %{
        "schedule_resident_id" => other.id,
        "resident_id" => other.resident_id,
        "name" => other.name
      })

    approved
    |> Ecto.Changeset.change(schedule_resident_id: other.id, target_snapshot: snapshot)
    |> Repo.update!()

    assert [%{kind: :rotation, code: "ambulatory"}] = duties(member)
    assert duties(other) == []
    assert diagnostics(member) == [F.diagnostic(source, :contradictory_identity)]
  end

  test "ambiguous observed identity excludes both source duties" do
    member = F.member()
    other = F.member(2026, 2)
    F.rotation(member, "ambulatory", @date, @date)
    one = F.source(member, @date, "Ultrasound")
    two = F.source(other, @date, "Ultrasound")
    updated = Repo.update!(Ecto.Changeset.change(two.source, raw_staff: one.source.raw_staff))
    two = %{two | source: updated}
    F.retain([one, two], false)

    assert [%{code: "ambulatory"}] = duties(member)
    assert duties(other) == []

    assert diagnostics(member) == [
             F.diagnostic(one, :ambiguous_identity),
             F.diagnostic(two, :ambiguous_identity)
           ]
  end

  test "missing source stays visible with a bounded diagnostic" do
    member = F.member()

    activity =
      Repo.insert!(%Activity{schedule_resident_id: member.id, date: @date, raw_task: "Vacation"})

    assert [%{code: "qgenda_assignment", timing: @date_only}] = duties(member)

    assert diagnostics(member) == [
             %{
               reason: :missing_source,
               activity_id: activity.id,
               activity_source_id: nil,
               schedule_resident_id: member.id,
               date: @date
             }
           ]
  end

  test "exact retained instants are honored by duties and the separate calendar identity set" do
    member = F.member()
    source = F.source(member, @date, "Ultrasound")
    F.retain([source])
    first = ~U[2026-11-03 14:15:00Z]
    last = ~U[2026-11-03 15:45:00Z]

    F.timing(source)
    |> Ecto.Changeset.change(
      precision: "exact",
      period: nil,
      starts_at: first,
      ends_at: last,
      time_zone: "Etc/UTC",
      policy: "exact_source",
      evidence_origin: "reviewed"
    )
    |> Repo.update!()

    assert [duty] = duties(member)

    assert duty.timing == %{
             precision: :exact,
             period: nil,
             starts_at: first,
             ends_at: last,
             time_zone: "Etc/UTC"
           }

    assert {:ok, [event]} = EffectiveSchedule.calendar_events(member.resident_id, :v2)
    assert event.dtstart == "20261103T141500Z"
    assert event.dtend == "20261103T154500Z"
    assert is_binary(event.uid)
    assert EffectiveSchedule.calendar_events(member.resident_id, :v2) == {:ok, [event]}
  end

  test "period-only activities never fabricate calendar clock hours" do
    member = F.member()
    source = F.source(member, @date, "Ultrasound", "PM")
    F.retain([source])
    assert [%{timing: %{precision: :period, period: "PM"}}] = duties(member)
    assert {:ok, [event]} = EffectiveSchedule.calendar_events(member.resident_id, :v2)
    assert event.dtstart == "20261103"
    assert event.dtend == "20261104"
  end

  test "equal source facts deduplicate while distinct same-code periods remain simultaneous" do
    member = F.member()
    morning = F.source(member, @date, "Ultrasound", "AM")
    duplicate = F.add_source(member, morning.activity)
    afternoon = F.add_source(member, morning.activity)
    F.retain([morning, duplicate, afternoon])

    F.timing(afternoon)
    |> Ecto.Changeset.change(period: "PM", evidence_origin: "reviewed")
    |> Repo.update!()

    assert [am, pm] = duties(member)
    assert am.code == "ultrasound" and pm.code == "ultrasound"
    assert am.timing == %{precision: :period, period: "AM"}
    assert pm.timing == %{precision: :period, period: "PM"}
    assert diagnostics(member) == []
  end

  test "contradictory classifications exclude conflicting source duties but retain independent facts" do
    member = F.member()
    F.rotation(member, "ambulatory", @date, @date)
    first = F.source(member, @date, "Ultrasound")
    second = F.add_source(member, first.activity)
    independent = F.source(member, @date, "Vacation")
    F.retain([first, second, independent])
    classification = F.classification(second)
    snapshot = Map.put(classification.mapping_snapshot, "target_codes", ["oncology"])
    classification |> Ecto.Changeset.change(mapping_snapshot: snapshot) |> Repo.update!()

    assert Enum.map(duties(member), & &1.code) |> Enum.sort() == [
             "ambulatory",
             "ultrasound",
             "vacation"
           ]

    assert diagnostics(member) == [F.diagnostic(second, :contradictory_classification)]
  end

  test "contradictory timing sources do not select arbitrary hours or suppress the base" do
    member = F.member()
    F.rotation(member, "ambulatory", @date, @date)
    first = F.source(member, @date, "Ultrasound", "AM")
    F.retain([first])
    F.timing(first) |> Ecto.Changeset.change(policy: "date_only") |> Repo.update!()

    assert [%{code: "ambulatory", timing: @date_only}] = duties(member)
    assert diagnostics(member) == [F.diagnostic(first, :contradictory_timing)]
  end

  test "diagnostics API preserves version and not-found contracts" do
    member = F.member()
    assert EffectiveSchedule.evidence_diagnostics(member.schedule_id, :v2) == {:ok, []}
    assert EffectiveSchedule.evidence_diagnostics(member.schedule_id, :legacy) == {:ok, []}
    assert EffectiveSchedule.evidence_diagnostics(-1, :v2) == {:error, :not_found}
    assert EffectiveSchedule.evidence_diagnostics(-1, :legacy) == {:error, :not_found}

    assert EffectiveSchedule.evidence_diagnostics(member.schedule_id, :other) ==
             {:error, :unknown_version}
  end

  test "same-label exact occurrences retain distinct stable calendar identities" do
    member = F.member()
    one = F.source(member, @date, "Ultrasound")
    two = F.add_source(member, one.activity)
    F.retain([one, two])

    for {source, first, last} <- [
          {one, ~U[2026-11-03 12:00:00Z], ~U[2026-11-03 13:00:00Z]},
          {two, ~U[2026-11-03 16:00:00Z], ~U[2026-11-03 17:00:00Z]}
        ] do
      F.timing(source)
      |> Ecto.Changeset.change(
        precision: "exact",
        period: nil,
        starts_at: first,
        ends_at: last,
        time_zone: "Etc/UTC",
        policy: "exact_source",
        evidence_origin: "reviewed"
      )
      |> Repo.update!()
    end

    assert length(duties(member)) == 2

    assert {:ok, [first, second] = events} =
             EffectiveSchedule.calendar_events(member.resident_id, :v2)

    assert first.dtstart == "20261103T120000Z"
    assert second.dtstart == "20261103T160000Z"
    assert first.uid != second.uid
    assert EffectiveSchedule.calendar_events(member.resident_id, :v2) == {:ok, events}
  end

  test "diagnostics have a total membership, date, activity, source and reason order" do
    member = F.member()
    other = F.member(2026, 2)
    later_member = F.source(other, ~D[2026-11-02], "Opaque B")
    later_date = F.source(member, ~D[2026-11-04], "Opaque A")
    earlier_date = F.source(member, ~D[2026-11-03], "Opaque C")

    expected =
      for source <- [earlier_date, later_date, later_member],
          reason <- [:missing_classification, :missing_identity, :missing_timing],
          do: F.diagnostic(source, reason)

    assert diagnostics(member) == expected
    assert diagnostics(member) == expected
  end

  test "unsupported retained classification versions and policies exclude only that source" do
    member = F.member()
    F.rotation(member, "ambulatory", @date, @date)
    source = F.source(member, @date, "SMH Obstetrics Resident 1st Contact Night")
    independent = F.source(member, @date, "Ultrasound")
    F.retain([source, independent])

    for {version, policy} <- [
          {"unsupported_rule_v3", "friday_strong_correction_v1"},
          {"legacy_task_classification_v1", "friday_strong_correction_v1"},
          {"legacy_task_classification_v2", "rotation_context_v1"}
        ] do
      retain_unsupported_policy(source, version, policy)
      assert Enum.map(duties(member), & &1.code) |> Enum.sort() == ["ambulatory", "ultrasound"]
      assert diagnostics(member) == [F.diagnostic(source, :contradictory_classification)]
    end
  end

  test "unsupported timing rule excludes its occurrence without changing independent duties" do
    member = F.member()
    F.rotation(member, "ambulatory", @date, @date)
    unsupported = F.source(member, @date, "Ultrasound", "AM")
    independent = F.source(member, @date, "Vacation")
    F.retain([unsupported, independent])

    F.timing(unsupported)
    |> Ecto.Changeset.change(rule_version: "unsupported_timing_v2")
    |> Repo.update!()

    assert Enum.map(duties(member), & &1.code) |> Enum.sort() == ["ambulatory", "vacation"]
    assert diagnostics(member) == [F.diagnostic(unsupported, :contradictory_timing)]
  end

  defp retain_unsupported_policy(source, version, policy) do
    alias ResidencySchedule.TaskMappings.Mapping, as: TaskMapping
    alias ResidencySchedule.TaskMappings.Target
    classification = F.classification(source)
    original = Repo.get!(TaskMapping, classification.mapping_id)

    facts =
      Map.take(original, [
        :namespace,
        :source_label,
        :lookup_key,
        :normalization_version,
        :recognized,
        :evidence_origin
      ])
      |> Map.merge(%{rule_version: version, policy: policy})

    codes = classification.mapping_snapshot["target_codes"]

    evidence =
      facts
      |> Map.put(:targets, codes)
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

    mapping =
      Repo.insert!(
        struct!(
          TaskMapping,
          Map.merge(facts, %{
            revision: original.revision + 1,
            current: false,
            evidence_snapshot: evidence
          })
        )
      )

    for code <- codes, do: Repo.insert!(%Target{mapping_id: mapping.id, activity_type_code: code})

    snapshot =
      Map.merge(classification.mapping_snapshot, %{
        "mapping_id" => mapping.id,
        "mapping_revision" => mapping.revision,
        "rule_version" => version,
        "policy" => policy,
        "evidence_snapshot" => evidence
      })

    digest =
      {classification.source_snapshot, snapshot}
      |> :erlang.term_to_binary([:deterministic])
      |> then(&:crypto.hash(:sha256, &1))
      |> Base.encode16(case: :lower)

    classification
    |> Ecto.Changeset.change(
      mapping_id: mapping.id,
      mapping_revision: mapping.revision,
      rule_version: version,
      mapping_snapshot: snapshot,
      input_digest: digest
    )
    |> Repo.update!()
  end

  defp record(member) do
    {:ok, records} = EffectiveSchedule.for_date(member.schedule_id, @date, :v2)
    Enum.find(records, &(&1.schedule_resident_id == member.id))
  end

  defp duties(member), do: record(member).duties

  defp diagnostics(member) do
    {:ok, diagnostics} = EffectiveSchedule.evidence_diagnostics(member.schedule_id, :v2)
    diagnostics
  end

  defp evidence_snapshot do
    Enum.map([Activity, ActivitySource, Mapping, Classification, Timing], fn schema ->
      schema |> order_by([r], r.id) |> Repo.all()
    end)
  end
end
