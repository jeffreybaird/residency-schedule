defmodule ResidencySchedule.Repo.Migrations.AddActivitySourceTimingsTest do
  use ResidencySchedule.DataCase

  alias ResidencySchedule.Repo.Migrations.AddActivitySourceTimings

  # Migrations live in priv/ and are not on the compile path. Load the file here
  # so both tests can call the real SQL regardless of test order.
  unless Code.ensure_loaded?(AddActivitySourceTimings) do
    for path <- Path.wildcard("priv/repo/migrations/*_add_activity_source_timings.exs"),
        do: Code.require_file(path)
  end

  @columns "original_source_id, activity_source_id, namespace, source_date, precision, period, starts_at, ends_at, time_zone, source_snapshot, input_digest, rule_version, policy, evidence_origin, inserted_at, updated_at"

  test "additive timing schema preserves populated legacy rows and old-shaped writes" do
    assert Path.wildcard("priv/repo/migrations/20261028120000_add_activity_source_timings.exs") !=
             []

    prefix = "timing_legacy_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{prefix}")
    Repo.query!("SET LOCAL search_path TO #{prefix}, public")

    for sql <- [
          "CREATE TABLE schedules (id bigint PRIMARY KEY, academic_year integer)",
          "CREATE TABLE residents (id bigint PRIMARY KEY, name text)",
          "CREATE TABLE schedule_residents (id bigint PRIMARY KEY, schedule_id bigint REFERENCES schedules(id), resident_id bigint REFERENCES residents(id))",
          "CREATE TABLE detailed_import_batches (id bigint PRIMARY KEY, schedule_id bigint, fingerprint text, source_kind text DEFAULT 'qgenda')",
          "CREATE TABLE detailed_activities (id bigint PRIMARY KEY, schedule_resident_id bigint REFERENCES schedule_residents(id), date date, raw_task text, period text)",
          "CREATE TABLE detailed_activity_sources (id bigint PRIMARY KEY, activity_id bigint REFERENCES detailed_activities(id), batch_id bigint REFERENCES detailed_import_batches(id), notes jsonb[])",
          "CREATE TABLE rotations (id bigint PRIMARY KEY, schedule_resident_id bigint, rotation_type text, start_date date, end_date date)"
        ],
        do: Repo.query!(sql)

    Repo.query!("INSERT INTO schedules VALUES (1,2026)")
    Repo.query!("INSERT INTO residents VALUES (2,'Iris Reed')")
    Repo.query!("INSERT INTO schedule_residents VALUES (3,1,2)")
    Repo.query!("INSERT INTO detailed_import_batches VALUES (4,1,'old-fingerprint','qgenda')")
    Repo.query!("INSERT INTO detailed_activities VALUES (5,3,'2026-12-30','SMH GYN R2 Day','PM')")

    Repo.query!(
      ~s|INSERT INTO detailed_activity_sources VALUES (6,5,4,ARRAY['{"text":"Preserve note"}'::jsonb])|
    )

    Repo.query!(
      "INSERT INTO rotations VALUES (7,3,'strong_gynecology','2026-12-28','2027-01-03')"
    )

    before = legacy_rows()

    for sql <- AddActivitySourceTimings.up_sql(), do: Repo.query!(sql)
    assert legacy_rows() == before
    assert [[0]] = Repo.query!("SELECT count(*) FROM activity_source_timings").rows

    assert [["activity_source_timings"]] =
             Repo.query!(
               "SELECT table_name FROM information_schema.tables WHERE table_schema=$1 AND table_name='activity_source_timings'",
               [prefix]
             ).rows

    Repo.query!(
      "INSERT INTO detailed_import_batches (id,schedule_id,fingerprint) VALUES (8,1,'new-fingerprint')"
    )

    Repo.query!("INSERT INTO detailed_activities VALUES (9,3,'2026-12-31','Vacation',NULL)")
    Repo.query!("INSERT INTO detailed_activity_sources (id,activity_id,batch_id) VALUES (10,9,8)")
    Repo.query!("INSERT INTO rotations VALUES (11,3,'vacation','2027-01-04','2027-01-10')")

    assert [["qgenda"]] =
             Repo.query!("SELECT source_kind FROM detailed_import_batches WHERE id=8").rows

    assert [["strong_gynecology"]] =
             Repo.query!("SELECT rotation_type FROM rotations WHERE id=7").rows

    assert_timing_constraints()
    assert_live_source_release()

    legacy_before_down = legacy_rows()
    for sql <- AddActivitySourceTimings.down_sql(), do: Repo.query!(sql)
    assert legacy_rows() == legacy_before_down

    assert [] =
             Repo.query!(
               "SELECT table_name FROM information_schema.tables WHERE table_schema=$1 AND table_name='activity_source_timings'",
               [prefix]
             ).rows

    assert [["SMH GYN R2 Day"]] =
             Repo.query!("SELECT raw_task FROM detailed_activities WHERE id=5").rows

    assert [[6]] = Repo.query!("SELECT id FROM detailed_activity_sources WHERE id=6").rows
    Repo.query!("SET LOCAL search_path TO public")
    Repo.query!("DROP SCHEMA #{prefix} CASCADE")
  end

  test "down removes only the new table" do
    assert AddActivitySourceTimings.down_sql() == ["DROP TABLE activity_source_timings"]
    assert Enum.all?(AddActivitySourceTimings.up_sql(), &is_binary/1)
    assert Enum.any?(AddActivitySourceTimings.up_sql(), &(&1 =~ "activity_source_timings"))
    refute Enum.any?(AddActivitySourceTimings.up_sql(), &(&1 =~ ~r/ALTER TABLE|DROP TABLE/i))
  end

  defp assert_timing_constraints do
    insert_timing!({6, 6, "'qgenda'", "'period'", "'PM'", "NULL", "NULL", "NULL"})
    insert_timing!({10, 10, "'csv'", "'date_only'", "NULL", "NULL", "NULL", "NULL"})

    insert_timing!(
      {11, "NULL", "'qgenda'", "'exact'", "NULL", "'2026-12-30 07:00:00-05'",
       "'2026-12-30 17:00:00-05'", "'America/New_York'"}
    )

    assert [["period", "PM", nil, nil, nil, 6]] =
             Repo.query!(
               "SELECT precision, period, starts_at, ends_at, time_zone, activity_source_id FROM activity_source_timings WHERE original_source_id=6"
             ).rows

    assert [["exact", nil, "America/New_York"]] =
             Repo.query!(
               "SELECT precision, period, time_zone FROM activity_source_timings WHERE original_source_id=11"
             ).rows

    rejected = [
      # exact without instants or zone
      {12, "NULL", "'qgenda'", "'exact'", "NULL", "NULL", "NULL", "NULL"},
      # exact without a zone
      {12, "NULL", "'qgenda'", "'exact'", "NULL", "'2026-12-30 07:00:00-05'",
       "'2026-12-30 17:00:00-05'", "NULL"},
      # exact whose end is not after its start
      {12, "NULL", "'qgenda'", "'exact'", "NULL", "'2026-12-30 17:00:00-05'",
       "'2026-12-30 17:00:00-05'", "'America/New_York'"},
      # exact together with a period
      {12, "NULL", "'qgenda'", "'exact'", "'PM'", "'2026-12-30 07:00:00-05'",
       "'2026-12-30 17:00:00-05'", "'America/New_York'"},
      # exact with an over-long zone name
      {12, "NULL", "'qgenda'", "'exact'", "NULL", "'2026-12-30 07:00:00-05'",
       "'2026-12-30 17:00:00-05'", "'#{String.duplicate("z", 65)}'"},
      # period with instants
      {12, "NULL", "'qgenda'", "'period'", "'PM'", "'2026-12-30 07:00:00-05'",
       "'2026-12-30 17:00:00-05'", "NULL"},
      # period with a zone only
      {12, "NULL", "'qgenda'", "'period'", "'PM'", "NULL", "NULL", "'America/New_York'"},
      # period without a label
      {12, "NULL", "'qgenda'", "'period'", "NULL", "NULL", "NULL", "NULL"},
      # period label outside the closed set
      {12, "NULL", "'qgenda'", "'period'", "'Evening'", "NULL", "NULL", "NULL"},
      # date_only with a period
      {12, "NULL", "'qgenda'", "'date_only'", "'PM'", "NULL", "NULL", "NULL"},
      # date_only with instants
      {12, "NULL", "'qgenda'", "'date_only'", "NULL", "'2026-12-30 07:00:00-05'",
       "'2026-12-30 17:00:00-05'", "'America/New_York'"},
      # unknown precision
      {12, "NULL", "'qgenda'", "'approximate'", "NULL", "NULL", "NULL", "NULL"},
      # namespace outside csv/qgenda
      {12, "NULL", "'other'", "'date_only'", "NULL", "NULL", "NULL", "NULL"},
      # live reference that is not the original source
      {12, 6, "'qgenda'", "'date_only'", "NULL", "NULL", "NULL", "NULL"},
      # duplicate original evidence
      {6, "NULL", "'qgenda'", "'date_only'", "NULL", "NULL", "NULL", "NULL"},
      # non-positive original id
      {0, "NULL", "'qgenda'", "'date_only'", "NULL", "NULL", "NULL", "NULL"}
    ]

    for fields <- rejected do
      assert_raise Postgrex.Error, fn -> insert_timing!(fields, mode: :savepoint) end
    end

    for {policy, origin} <- [{"'guessed'", "'legacy_code'"}, {"'date_only'", "'bot'"}] do
      assert_raise Postgrex.Error, fn ->
        Repo.query!(
          "INSERT INTO activity_source_timings (#{@columns}) VALUES (12, NULL, 'qgenda', '2026-12-30', 'date_only', NULL, NULL, NULL, NULL, '{}'::jsonb, 'digest', 'legacy_timing_v1', #{policy}, #{origin}, now(), now())",
          [],
          mode: :savepoint
        )
      end
    end

    assert [[3]] = Repo.query!("SELECT count(*) FROM activity_source_timings").rows
  end

  defp assert_live_source_release do
    Repo.query!("DELETE FROM detailed_activity_sources WHERE id=10")

    assert [[nil, 10, "date_only"]] =
             Repo.query!(
               "SELECT activity_source_id, original_source_id, precision FROM activity_source_timings WHERE original_source_id=10"
             ).rows

    assert [[6]] =
             Repo.query!(
               "SELECT activity_source_id FROM activity_source_timings WHERE original_source_id=6"
             ).rows
  end

  defp insert_timing!(fields, opts \\ []) do
    {original, live, namespace, precision, period, starts, ends, zone} = fields

    Repo.query!(
      ~s|INSERT INTO activity_source_timings (#{@columns}) VALUES (#{original}, #{live}, #{namespace}, '2026-12-30', #{precision}, #{period}, #{starts}, #{ends}, #{zone}, '{"date":"2026-12-30"}'::jsonb, 'digest-#{original}-#{System.unique_integer([:positive])}', 'legacy_timing_v1', #{policy_for(precision)}, 'legacy_code', now(), now())|,
      [],
      opts
    )
  end

  defp policy_for("'period'"), do: "'stored_period'"
  defp policy_for("'date_only'"), do: "'date_only'"
  defp policy_for(_other), do: "'exact_source'"

  defp legacy_rows do
    Map.new(
      [
        "schedules",
        "residents",
        "schedule_residents",
        "detailed_import_batches",
        "detailed_activities",
        "detailed_activity_sources",
        "rotations"
      ],
      fn table ->
        {table, Repo.query!("SELECT to_jsonb(t) FROM #{table} t ORDER BY id").rows}
      end
    )
  end
end
