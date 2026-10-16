defmodule ResidencySchedule.StagingFixturesTest do
  use ResidencySchedule.DataCase, async: false

  alias Ecto.Adapters.SQL
  alias ResidencySchedule.Accounts
  alias ResidencySchedule.Accounts.{MagicLinkToken, User}

  alias ResidencySchedule.DetailedSchedules.{
    Activity,
    ActivitySource,
    ImportBatch,
    TaskEquivalence
  }

  alias ResidencySchedule.Ical
  alias ResidencySchedule.Release
  alias ResidencySchedule.Residents.{Resident, ScheduleResident}
  alias ResidencySchedule.Rotations
  alias ResidencySchedule.Rotations.Rotation
  alias ResidencySchedule.Schedules.Schedule
  alias ResidencySchedule.ShiftOverrides.ShiftOverride
  alias ResidencySchedule.StagingFixtures

  doctest StagingFixtures

  @schemas [
    Schedule,
    Resident,
    ScheduleResident,
    Rotation,
    Activity,
    ShiftOverride,
    ActivitySource,
    ImportBatch,
    User,
    MagicLinkToken
  ]

  setup do
    variables = ~w(CONFIG_ENVIRONMENT EXPECTED_DATABASE_NAME)
    previous = Map.new(variables, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {key, nil} -> System.delete_env(key)
        {key, value} -> System.put_env(key, value)
      end)
    end)

    :ok
  end

  test "target validation requires the staging environment and both exact database identities" do
    assert :ok =
             StagingFixtures.validate_target(
               "staging",
               "residency_schedule_staging",
               "residency_schedule_staging"
             )

    for {environment, expected, actual} <- [
          {nil, "residency_schedule_staging", "residency_schedule_staging"},
          {"prod", "residency_schedule_staging", "residency_schedule_staging"},
          {"demo", "residency_schedule_staging", "residency_schedule_staging"},
          {"staging", nil, "residency_schedule_staging"},
          {"staging", "residency_schedule", "residency_schedule_staging"},
          {"staging", "residency_schedule_staging", "residency_schedule"},
          {"staging", "residency_schedule_staging", "residency_schedule_demo"},
          {"staging", "residency_schedule_staging", "residency_schedule_test"},
          {"staging", "residency_schedule_staging", nil}
        ] do
      assert {:error, :not_staging} =
               StagingFixtures.validate_target(environment, expected, actual)
    end
  end

  test "manual release seed refuses a non-staging actual database before any write" do
    %{rows: [[actual_database]]} = SQL.query!(Repo, "SELECT current_database()", [])
    refute actual_database == "residency_schedule_staging"
    before = snapshot()

    for {environment, database} <- [
          {"staging", "residency_schedule_staging"},
          {"prod", "residency_schedule_staging"},
          {"demo", "residency_schedule_staging"},
          {"staging", actual_database},
          {nil, nil}
        ] do
      put_or_delete("CONFIG_ENVIRONMENT", environment)
      put_or_delete("EXPECTED_DATABASE_NAME", database)
      assert {:error, :not_staging} = Release.seed_staging()
      assert snapshot() == before
    end
  end

  test "synthetic fixtures connect the same people across three academic years" do
    assert {:ok, _summary} = StagingFixtures.seed()

    schedules = Repo.all(from s in Schedule, order_by: s.academic_year)
    assert Enum.map(schedules, & &1.academic_year) == [2025, 2026, 2027]

    for name <- ["Stage Briar", "Stage Rowan"] do
      resident = Repo.get_by!(Resident, name: name)
      assert is_binary(resident.calendar_token) and byte_size(resident.calendar_token) > 0

      appearances =
        Repo.all(
          from sr in ScheduleResident,
            where: sr.resident_id == ^resident.id,
            join: s in assoc(sr, :schedule),
            order_by: s.academic_year,
            select: s.academic_year
        )

      assert appearances == [2025, 2026, 2027]
    end

    tokens = Repo.all(from r in Resident, select: r.calendar_token)
    assert length(Enum.uniq(tokens)) == length(tokens)
    assert Repo.aggregate(Rotation, :count) > 0
    assert Repo.aggregate(Activity, :count) > 0
  end

  test "fixtures include coverage history, overnight activity and the complete April vacation chain" do
    assert {:ok, _summary} = StagingFixtures.seed()

    historical_coverage =
      Repo.all(
        from override in ShiftOverride,
          join: rotation in assoc(override, :rotation),
          join: original in assoc(rotation, :schedule_resident),
          join: covering in assoc(override, :covering_schedule_resident),
          join: schedule in assoc(original, :schedule),
          where: schedule.academic_year == 2025,
          select: {original.resident_id, covering.resident_id, override}
      )

    assert Enum.any?(historical_coverage, fn {original, covering, override} ->
             original != covering and
               Date.compare(override.override_start_date, override.override_end_date) != :gt
           end)

    assert Repo.exists?(from a in Activity, where: a.period == "Night")
    briar = Repo.get_by!(Resident, name: "Stage Briar")

    roster_vacations =
      Repo.all(
        from r in Rotation,
          join: sr in assoc(r, :schedule_resident),
          where: sr.resident_id == ^briar.id and r.rotation_type == "vacation"
      )

    assert Enum.sort(Enum.map(roster_vacations, &{&1.start_date, &1.end_date})) ==
             [{~D[2027-04-05], ~D[2027-04-09]}, {~D[2027-04-12], ~D[2027-04-16]}]

    weekend_vacations =
      Repo.all(
        from a in Activity,
          join: sr in assoc(a, :schedule_resident),
          where: sr.resident_id == ^briar.id and a.raw_task == "Vacation",
          order_by: a.date,
          preload: [sources: :batch]
      )

    assert Enum.map(weekend_vacations, & &1.date) ==
             [~D[2027-04-10], ~D[2027-04-11], ~D[2027-04-17], ~D[2027-04-18]]

    for activity <- weekend_vacations do
      assert Enum.any?(activity.sources, fn source ->
               is_binary(source.source_sheet) and source.source_sheet != "" and
                 is_binary(source.source_cell) and source.source_cell != "" and
                 Date.compare(source.batch.header_start, activity.date) != :gt and
                 Date.compare(source.batch.header_end, activity.date) != :lt and
                 source.notes != []
             end)
    end

    vacations =
      briar.id
      |> Rotations.effective_segments_for_person()
      |> Enum.filter(&(&1.rotation_type == "vacation"))

    for date <- Date.range(~D[2027-04-05], ~D[2027-04-18]) do
      assert Enum.any?(vacations, fn rotation ->
               Date.compare(rotation.start_date, date) != :gt and
                 Date.compare(rotation.end_date, date) != :lt
             end),
             "vacation chain is missing #{date}"
    end
  end

  test "detailed clinic activity coexists with a rotation and overnight duties cross midnight" do
    assert {:ok, _summary} = StagingFixtures.seed()
    activities = Repo.all(Activity)

    assert activities
           |> Enum.group_by(&{&1.schedule_resident_id, &1.date})
           |> Enum.any?(fn {_identity, tasks} ->
             Enum.any?(tasks, &String.contains?(String.downcase(&1.raw_task), "clinic")) and
               Enum.any?(tasks, &TaskEquivalence.matches_rotation?(&1.raw_task, "oncology"))
           end)

    segments =
      Repo.all(Resident)
      |> Enum.flat_map(&Rotations.effective_segments_for_person(&1.id))

    night = Enum.find(segments, &Ical.night_shift?(&1.rotation_type))
    refute is_nil(night)
    {starts, finishes} = Ical.event_times(night.rotation_type, night.start_date)
    assert starts == Calendar.strftime(Date.add(night.start_date, -1), "%Y%m%d") <> "T180000"
    assert finishes == Calendar.strftime(night.start_date, "%Y%m%d") <> "T060000"
  end

  test "fixture conflicts refuse existing same-name people without attaching or replacing data" do
    Repo.insert!(%Resident{name: "Stage Rowan", calendar_token: "existing-unowned-feed"})
    before = snapshot()
    assert {:error, :fixture_conflict} = StagingFixtures.seed()
    assert snapshot() == before
  end

  test "fixture conflicts refuse a preexisting academic year with a different label atomically" do
    Repo.insert!(%Schedule{academic_year: 2027, label: "Operator-managed rehearsal"})
    before = snapshot()
    assert {:error, :fixture_conflict} = StagingFixtures.seed()
    assert snapshot() == before
  end

  test "fixture conflicts preserve operator changes to an existing fixture rotation" do
    assert {:ok, _summary} = StagingFixtures.seed()
    rotation = Repo.one!(from r in Rotation, order_by: r.id, limit: 1)
    rotation |> Ecto.Changeset.change(rotation_type: "manual_rehearsal") |> Repo.update!()
    before = snapshot()
    assert {:error, :fixture_conflict} = StagingFixtures.seed()
    assert snapshot() == before
  end

  test "synthetic admin has no seeded password and reruns preserve operator authentication state" do
    assert {:ok, _summary} = StagingFixtures.seed()
    admin = Accounts.get_user_by_email("staging-admin@example.test")
    refute is_nil(admin)
    assert admin.role == :admin
    assert admin.approved
    refute admin.denied
    assert is_nil(admin.password_hash)
    refute Repo.exists?(MagicLinkToken)

    assert {:ok, admin} = Accounts.set_password(admin, "operator-test-only-password")
    assert {:ok, token} = Accounts.generate_magic_link_token(admin)
    before = snapshot()
    assert {:ok, _summary} = StagingFixtures.seed()
    assert snapshot() == before

    assert {:ok, preserved} =
             Accounts.authenticate_by_password(admin.email, "operator-test-only-password")

    assert preserved.id == admin.id
    assert {:ok, token_user} = Accounts.validate_magic_link_token(token)
    assert token_user.id == admin.id
  end

  test "seeding refuses to silently promote an existing account with the staging admin email" do
    Repo.insert!(%User{email: "staging-admin@example.test", role: :user, approved: false})
    before = snapshot()
    assert {:error, :fixture_conflict} = StagingFixtures.seed()
    assert snapshot() == before
  end

  test "rerunning the fixture seed preserves row identities, feed tokens and manual records" do
    assert {:ok, _summary} = StagingFixtures.seed()
    briar = Repo.get_by!(Resident, name: "Stage Briar")

    briar
    |> Ecto.Changeset.change(calendar_token: "operator-preserved-staging-feed")
    |> Repo.update!()

    appearance =
      Repo.one!(from sr in ScheduleResident, where: sr.resident_id == ^briar.id, limit: 1)

    Repo.insert!(%Activity{
      schedule_resident_id: appearance.id,
      date: ~D[2026-10-16],
      raw_task: "Manual rehearsal annotation",
      period: "Day"
    })

    Repo.insert!(%Resident{
      name: "Manual Synthetic Person",
      calendar_token: "manual-independent-feed"
    })

    before = snapshot()
    assert {:ok, _summary} = StagingFixtures.seed()
    assert snapshot() == before
    assert Repo.get!(Resident, briar.id).calendar_token == "operator-preserved-staging-feed"
  end

  defp snapshot do
    Map.new(@schemas, fn schema -> {schema, Repo.all(from row in schema, order_by: row.id)} end)
  end

  defp put_or_delete(key, nil), do: System.delete_env(key)
  defp put_or_delete(key, value), do: System.put_env(key, value)
end
