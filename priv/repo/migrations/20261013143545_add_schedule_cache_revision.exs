defmodule ResidencySchedule.Repo.Migrations.AddScheduleCacheRevision do
  use Ecto.Migration

  @tables ~w(schedules residents schedule_residents rotations shift_overrides detailed_activities detailed_activity_sources)

  def up do
    execute(
      "CREATE TABLE schedule_cache_revision (id integer PRIMARY KEY CHECK (id = 1), revision bigint NOT NULL)"
    )

    execute("INSERT INTO schedule_cache_revision (id, revision) VALUES (1, 0)")

    execute("""
    CREATE FUNCTION advance_schedule_cache_revision() RETURNS trigger AS $$
    BEGIN
      IF current_setting('residency_schedule.skip_cache_revision', true) IS DISTINCT FROM 'on' THEN
        UPDATE schedule_cache_revision SET revision = revision + 1 WHERE id = 1;
      END IF;
      RETURN NULL;
    END;
    $$ LANGUAGE plpgsql;
    """)

    for table <- @tables do
      execute("""
      CREATE TRIGGER advance_schedule_cache_revision
      BEFORE INSERT OR UPDATE OR DELETE OR TRUNCATE ON #{table}
      FOR EACH STATEMENT EXECUTE FUNCTION advance_schedule_cache_revision()
      """)
    end
  end

  def down do
    for table <- @tables do
      execute("DROP TRIGGER advance_schedule_cache_revision ON #{table}")
    end

    execute("DROP FUNCTION advance_schedule_cache_revision()")
    execute("DROP TABLE schedule_cache_revision")
  end
end
