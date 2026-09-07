defmodule ResidencySchedule.Repo.Migrations.MoveIdentityToResidents do
  @moduledoc """
  A resident is one person across every imported schedule, so the things that
  identify that person — the calendar feed token and a user's home link — move
  from the per-year `schedule_residents` row onto the `residents` row.

  Re-importing a year deletes and recreates its `schedule_residents`, which
  used to invalidate every subscribed feed URL and nil out every user's home
  resident for that year. Both now survive re-imports and rollover.
  """
  use Ecto.Migration

  def up do
    alter table(:residents) do
      add :calendar_token, :string
    end

    # Keep the most recently issued token per person so existing subscriptions
    # keep working where possible.
    execute """
    UPDATE residents r
    SET calendar_token = latest.calendar_token
    FROM (
      SELECT DISTINCT ON (resident_id) resident_id, calendar_token
      FROM schedule_residents
      WHERE calendar_token IS NOT NULL
      ORDER BY resident_id, inserted_at DESC, id DESC
    ) latest
    WHERE latest.resident_id = r.id
    """

    execute """
    UPDATE residents
    SET calendar_token = gen_random_uuid()::text
    WHERE calendar_token IS NULL
    """

    alter table(:residents) do
      modify :calendar_token, :string, null: false
    end

    create unique_index(:residents, [:calendar_token])

    alter table(:schedule_residents) do
      remove :calendar_token
    end

    execute "ALTER TABLE users DROP CONSTRAINT users_home_resident_id_fkey"

    execute """
    UPDATE users u
    SET home_resident_id = sr.resident_id
    FROM schedule_residents sr
    WHERE sr.id = u.home_resident_id
    """

    execute """
    UPDATE users
    SET home_resident_id = NULL
    WHERE home_resident_id IS NOT NULL
      AND home_resident_id NOT IN (SELECT id FROM residents)
    """

    execute """
    ALTER TABLE users
    ADD CONSTRAINT users_home_resident_id_fkey
    FOREIGN KEY (home_resident_id) REFERENCES residents(id) ON DELETE SET NULL
    """
  end

  def down do
    execute "ALTER TABLE users DROP CONSTRAINT users_home_resident_id_fkey"

    # Point each user at the person's most recent schedule appearance.
    execute """
    UPDATE users u
    SET home_resident_id = latest.id
    FROM (
      SELECT DISTINCT ON (sr.resident_id) sr.resident_id, sr.id
      FROM schedule_residents sr
      JOIN schedules s ON s.id = sr.schedule_id
      ORDER BY sr.resident_id, s.academic_year DESC
    ) latest
    WHERE latest.resident_id = u.home_resident_id
    """

    execute """
    UPDATE users
    SET home_resident_id = NULL
    WHERE home_resident_id IS NOT NULL
      AND home_resident_id NOT IN (SELECT id FROM schedule_residents)
    """

    execute """
    ALTER TABLE users
    ADD CONSTRAINT users_home_resident_id_fkey
    FOREIGN KEY (home_resident_id) REFERENCES schedule_residents(id) ON DELETE SET NULL
    """

    alter table(:schedule_residents) do
      add :calendar_token, :string
    end

    # Per-year tokens cannot be recovered once collapsed onto the person, so
    # rolling back issues fresh ones and existing feed subscriptions break.
    execute "UPDATE schedule_residents SET calendar_token = gen_random_uuid()::text"

    create unique_index(:schedule_residents, [:calendar_token])

    alter table(:residents) do
      remove :calendar_token
    end
  end
end
