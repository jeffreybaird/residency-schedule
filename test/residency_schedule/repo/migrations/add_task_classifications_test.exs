defmodule ResidencySchedule.Repo.Migrations.AddTaskClassificationsTest do
  use ResidencySchedule.DataCase

  alias ResidencySchedule.Repo.Migrations.AddTaskClassifications

  test "additive schema preserves populated legacy rows and old-shaped writes" do
    unless Code.ensure_loaded?(AddTaskClassifications) do
      for path <- Path.wildcard("priv/repo/migrations/*_add_task_classifications.exs"),
          do: Code.require_file(path)
    end

    prefix = "task_legacy_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{prefix}")
    Repo.query!("SET LOCAL search_path TO #{prefix}, public")

    for sql <- [
          "CREATE TABLE schedules (id bigint PRIMARY KEY, academic_year integer)",
          "CREATE TABLE residents (id bigint PRIMARY KEY, name text)",
          "CREATE TABLE schedule_residents (id bigint PRIMARY KEY, schedule_id bigint REFERENCES schedules(id), resident_id bigint REFERENCES residents(id))",
          "CREATE TABLE detailed_import_batches (id bigint PRIMARY KEY, schedule_id bigint, fingerprint text, source_kind text DEFAULT 'qgenda')",
          "CREATE TABLE detailed_activities (id bigint PRIMARY KEY, schedule_resident_id bigint REFERENCES schedule_residents(id), date date, raw_task text)",
          "CREATE TABLE detailed_activity_sources (id bigint PRIMARY KEY, activity_id bigint REFERENCES detailed_activities(id), batch_id bigint REFERENCES detailed_import_batches(id), notes jsonb[])",
          "CREATE TABLE rotations (id bigint PRIMARY KEY, schedule_resident_id bigint, rotation_type text, start_date date, end_date date)"
        ],
        do: Repo.query!(sql)

    Repo.query!("INSERT INTO schedules VALUES (1,2026)")
    Repo.query!("INSERT INTO residents VALUES (2,'Iris Reed')")
    Repo.query!("INSERT INTO schedule_residents VALUES (3,1,2)")
    Repo.query!("INSERT INTO detailed_import_batches VALUES (4,1,'old-fingerprint','qgenda')")
    Repo.query!("INSERT INTO detailed_activities VALUES (5,3,'2026-12-30','SMH GYN R2 Day')")

    Repo.query!(
      ~s|INSERT INTO detailed_activity_sources VALUES (6,5,4,ARRAY['{"text":"Preserve note"}'::jsonb])|
    )

    Repo.query!(
      "INSERT INTO rotations VALUES (7,3,'strong_gynecology','2026-12-28','2027-01-03')"
    )

    before = legacy_rows()

    for sql <- AddTaskClassifications.up_sql(), do: Repo.query!(sql)
    assert legacy_rows() == before

    for table <- [
          "activity_types",
          "source_task_mappings",
          "source_task_mapping_targets",
          "activity_source_classifications"
        ] do
      assert [[0]] = Repo.query!("SELECT count(*) FROM #{table}").rows
    end

    Repo.query!(
      "INSERT INTO detailed_import_batches (id,schedule_id,fingerprint) VALUES (8,1,'new-fingerprint')"
    )

    Repo.query!("INSERT INTO detailed_activities VALUES (9,3,'2026-12-31','Vacation')")
    Repo.query!("INSERT INTO detailed_activity_sources (id,activity_id,batch_id) VALUES (10,9,8)")
    Repo.query!("INSERT INTO rotations VALUES (11,3,'vacation','2027-01-04','2027-01-10')")

    assert [["qgenda"]] =
             Repo.query!("SELECT source_kind FROM detailed_import_batches WHERE id=8").rows

    assert [["strong_gynecology"]] =
             Repo.query!("SELECT rotation_type FROM rotations WHERE id=7").rows

    for sql <- AddTaskClassifications.down_sql(), do: Repo.query!(sql)

    assert [["SMH GYN R2 Day"]] =
             Repo.query!("SELECT raw_task FROM detailed_activities WHERE id=5").rows

    assert [[10]] = Repo.query!("SELECT id FROM detailed_activity_sources WHERE id=10").rows
    Repo.query!("SET LOCAL search_path TO public")
    Repo.query!("DROP SCHEMA #{prefix} CASCADE")
  end

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
