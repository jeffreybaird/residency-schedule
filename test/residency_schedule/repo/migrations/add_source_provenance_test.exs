defmodule ResidencySchedule.Repo.Migrations.AddSourceProvenanceTest do
  use ResidencySchedule.DataCase

  alias ResidencySchedule.Repo.Migrations.AddSourceProvenance
  alias ResidencySchedule.SourceProvenance

  unless Code.ensure_loaded?(AddSourceProvenance) do
    for path <- Path.wildcard("priv/repo/migrations/*_add_source_provenance.exs") do
      Code.require_file(path)
    end
  end

  test "real migration SQL expands populated legacy tables without rewriting records or references" do
    prefix = "provenance_legacy_#{System.unique_integer([:positive])}"
    Repo.query!("CREATE SCHEMA #{prefix}")
    Repo.query!("SET LOCAL search_path TO #{prefix}, public")
    create_legacy_tables()
    insert_legacy_rows()
    before = legacy_snapshot()

    for sql <- AddSourceProvenance.up_sql(), do: Repo.query!(sql)

    assert legacy_snapshot() == before

    assert [["legacy", %{}]] =
             Repo.query!("SELECT source_kind, source_metadata FROM rotations WHERE id = 101").rows

    assert [["qgenda", %{}]] =
             Repo.query!(
               "SELECT source_kind, source_metadata FROM detailed_import_batches WHERE id = 701"
             ).rows

    assert [[%{}]] =
             Repo.query!("SELECT source_reference FROM detailed_activity_sources WHERE id = 901").rows

    assert {:ok, %{activity_sources_updated: 1}} = SourceProvenance.backfill(batch_size: 1)

    assert [[%{"sheet" => "December", "cell" => "D6"}]] =
             Repo.query!("SELECT source_reference FROM detailed_activity_sources WHERE id = 901").rows

    assert {:ok, %{activity_sources_updated: 0}} = SourceProvenance.backfill(batch_size: 1)
    assert legacy_snapshot() == before

    assert [[101, "approved", "Keep coverage note"]] =
             Repo.query!("SELECT rotation_id, status, note FROM coverage_links WHERE id = 201").rows

    # Simulate writes from a binary that does not know the new provenance fields.
    Repo.query!("INSERT INTO rotations (id, rotation_type) VALUES (102, 'vacation')")

    Repo.query!(
      "INSERT INTO detailed_import_batches (id, fingerprint) VALUES (702, 'another-fingerprint')"
    )

    Repo.query!(
      "INSERT INTO detailed_activity_sources (id, activity_id, batch_id, source_sheet, source_cell) VALUES (902, 801, 702, 'January', 'F8')"
    )

    assert [["legacy", %{}]] =
             Repo.query!("SELECT source_kind, source_metadata FROM rotations WHERE id = 102").rows

    assert [["qgenda", %{}]] =
             Repo.query!(
               "SELECT source_kind, source_metadata FROM detailed_import_batches WHERE id = 702"
             ).rows

    assert [[%{}]] =
             Repo.query!("SELECT source_reference FROM detailed_activity_sources WHERE id = 902").rows

    assert {:ok, %{activity_sources_updated: 1}} = SourceProvenance.backfill(batch_size: 1)

    assert [[%{"sheet" => "January", "cell" => "F8"}]] =
             Repo.query!("SELECT source_reference FROM detailed_activity_sources WHERE id = 902").rows

    # The additive down path removes only its own columns in this isolated schema.
    for sql <- AddSourceProvenance.down_sql(), do: Repo.query!(sql)
    assert [[101]] = Repo.query!("SELECT rotation_id FROM coverage_links WHERE id = 201").rows
    Repo.query!("SET LOCAL search_path TO public")
    Repo.query!("DROP SCHEMA #{prefix} CASCADE")
  end

  defp create_legacy_tables do
    for sql <- [
          "CREATE TABLE rotations (id bigint PRIMARY KEY, schedule_resident_id bigint, rotation_type text, start_date date, end_date date, slot_index integer, inserted_at timestamp, updated_at timestamp)",
          "CREATE TABLE coverage_links (id bigint PRIMARY KEY, rotation_id bigint REFERENCES rotations(id), status text, note text)",
          "CREATE TABLE detailed_import_batches (id bigint PRIMARY KEY, schedule_id bigint, created_by_id bigint, fingerprint text, header_start date, header_end date, inserted_at timestamp, updated_at timestamp)",
          "CREATE TABLE detailed_activities (id bigint PRIMARY KEY, schedule_resident_id bigint, date date, raw_task text, period text, site text, inserted_at timestamp, updated_at timestamp)",
          "CREATE TABLE detailed_activity_sources (id bigint PRIMARY KEY, activity_id bigint REFERENCES detailed_activities(id), batch_id bigint REFERENCES detailed_import_batches(id), source_sheet text NOT NULL, source_cell text NOT NULL, raw_staff text, display_name text, previous_name text, notes jsonb[], inserted_at timestamp, updated_at timestamp)",
          "CREATE UNIQUE INDEX detailed_source_identity ON detailed_activity_sources (batch_id, source_sheet, source_cell)"
        ],
        do: Repo.query!(sql)
  end

  defp insert_legacy_rows do
    Repo.query!(
      "INSERT INTO rotations VALUES (101, 301, 'strong_gynecology', '2026-12-28', '2027-01-01', 7, '2025-01-01 12:00:00', '2025-01-02 12:00:00')"
    )

    Repo.query!("INSERT INTO coverage_links VALUES (201, 101, 'approved', 'Keep coverage note')")

    Repo.query!(
      "INSERT INTO detailed_import_batches VALUES (701, 401, 501, 'same-old-fingerprint', '2026-12-28', '2027-01-03', '2025-01-01 12:00:00', '2025-01-02 12:00:00')"
    )

    Repo.query!(
      "INSERT INTO detailed_activities VALUES (801, 301, '2026-12-29', 'Clinic PM', 'PM', 'SMH', '2025-01-01 12:00:00', '2025-01-02 12:00:00')"
    )

    Repo.query!(
      ~s|INSERT INTO detailed_activity_sources VALUES (901, 801, 701, 'December', 'D6', 'Reed, Iris', 'Iris Reed', 'Iris', ARRAY['{"text":"Keep activity note"}'::jsonb], '2025-01-01 12:00:00', '2025-01-02 12:00:00')|
    )
  end

  defp legacy_snapshot do
    for table <- [
          "rotations",
          "coverage_links",
          "detailed_import_batches",
          "detailed_activities",
          "detailed_activity_sources"
        ] do
      {table,
       Repo.query!(
         "SELECT to_jsonb(t) - 'source_kind' - 'source_metadata' - 'source_reference' FROM #{table} t ORDER BY id"
       ).rows}
    end
  end
end
