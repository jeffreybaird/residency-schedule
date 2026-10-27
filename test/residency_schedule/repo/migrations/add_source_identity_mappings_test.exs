defmodule ResidencySchedule.Repo.Migrations.AddSourceIdentityMappingsTest do
  use ResidencySchedule.DataCase

  alias ResidencySchedule.Repo.Migrations.AddSourceIdentityMappings

  unless Code.ensure_loaded?(AddSourceIdentityMappings) do
    for path <- Path.wildcard("priv/repo/migrations/*_add_source_identity_mappings.exs"),
        do: Code.require_file(path)
  end

  test "additive migration preserves populated legacy rows and omitted-column writes" do
    prefix = "identity_legacy_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{prefix}")
    Repo.query!("SET LOCAL search_path TO #{prefix}, public")

    for sql <- [
          "CREATE TABLE users (id bigint PRIMARY KEY)",
          "CREATE TABLE schedules (id bigint PRIMARY KEY, academic_year integer)",
          "CREATE TABLE residents (id bigint PRIMARY KEY, name text)",
          "CREATE TABLE schedule_residents (id bigint PRIMARY KEY, schedule_id bigint REFERENCES schedules(id) ON DELETE CASCADE, resident_id bigint REFERENCES residents(id), position_code text)",
          "CREATE TABLE detailed_import_batches (id bigint PRIMARY KEY, schedule_id bigint, fingerprint text, source_kind text DEFAULT 'qgenda')",
          "CREATE TABLE detailed_activities (id bigint PRIMARY KEY, schedule_resident_id bigint REFERENCES schedule_residents(id) ON DELETE CASCADE, raw_task text)",
          "CREATE TABLE detailed_activity_sources (id bigint PRIMARY KEY, activity_id bigint REFERENCES detailed_activities(id) ON DELETE CASCADE, batch_id bigint REFERENCES detailed_import_batches(id), raw_staff text, notes jsonb[], inserted_at timestamp)"
        ],
        do: Repo.query!(sql)

    Repo.query!("INSERT INTO users VALUES (501)")
    Repo.query!("INSERT INTO schedules VALUES (401, 2026), (402, 2025)")
    Repo.query!("INSERT INTO residents VALUES (201, 'Iris Reed')")
    Repo.query!("INSERT INTO schedule_residents VALUES (301, 401, 201, 'R2-1')")

    Repo.query!(
      "INSERT INTO detailed_import_batches VALUES (701, 401, 'old-fingerprint', 'qgenda')"
    )

    Repo.query!("INSERT INTO detailed_activities VALUES (801, 301, 'Clinic PM')")

    Repo.query!(
      ~s|INSERT INTO detailed_activity_sources VALUES (901, 801, 701, 'Reed, Iris', ARRAY['{"text":"Keep note"}'::jsonb], '2025-01-01 12:00:00')|
    )

    before = old_rows()
    for sql <- AddSourceIdentityMappings.up_sql(), do: Repo.query!(sql)
    assert old_rows() == before
    assert [[0]] = Repo.query!("SELECT count(*) FROM source_identity_mappings").rows
    # A binary unaware of identity mappings continues to insert old-shaped rows.
    Repo.query!("INSERT INTO residents VALUES (202, 'Other Person')")
    Repo.query!("INSERT INTO schedule_residents VALUES (302, 401, 202, 'R2-2')")

    Repo.query!(
      "INSERT INTO detailed_import_batches (id, schedule_id, fingerprint) VALUES (702, 401, 'new-fingerprint')"
    )

    assert [["qgenda"]] =
             Repo.query!("SELECT source_kind FROM detailed_import_batches WHERE id=702").rows

    assert [[301]] =
             Repo.query!("SELECT schedule_resident_id FROM detailed_activities WHERE id=801").rows

    for sql <- AddSourceIdentityMappings.down_sql(), do: Repo.query!(sql)

    assert [[301]] =
             Repo.query!("SELECT schedule_resident_id FROM detailed_activities WHERE id=801").rows

    Repo.query!("SET LOCAL search_path TO public")
    Repo.query!("DROP SCHEMA #{prefix} CASCADE")
  end

  defp old_rows do
    for table <- [
          "users",
          "schedules",
          "residents",
          "schedule_residents",
          "detailed_import_batches",
          "detailed_activities",
          "detailed_activity_sources"
        ] do
      {table, Repo.query!("SELECT to_jsonb(t) FROM #{table} t ORDER BY id").rows}
    end
  end
end
