defmodule ResidencySchedule.Repo.Migrations.ExtractResidentPeople do
  use Ecto.Migration

  def up do
    # 1. Rename current residents to a temp table
    rename table(:residents), to: table(:resident_positions_old)

    # 2. Create new residents table (one row per physical person)
    create table(:residents) do
      add :name, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:residents, [:name])

    # 3. Populate residents with distinct names from old table
    execute """
    INSERT INTO residents (name, inserted_at, updated_at)
    SELECT DISTINCT ON (name) name, NOW(), NOW()
    FROM resident_positions_old
    ORDER BY name, inserted_at DESC
    """

    # 4. Create schedule_residents (person × schedule year position)
    create table(:schedule_residents) do
      add :resident_id, references(:residents, on_delete: :delete_all), null: false
      add :schedule_id, references(:schedules, on_delete: :delete_all), null: false
      add :position_code, :string, null: false
      add :residency_year, :integer, null: false
      add :schedule_number, :integer, null: false
      add :calendar_token, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:schedule_residents, [:schedule_id, :position_code])
    create unique_index(:schedule_residents, [:schedule_id, :resident_id])
    create unique_index(:schedule_residents, [:calendar_token])
    create index(:schedule_residents, [:resident_id])
    create index(:schedule_residents, [:schedule_id])

    # 5. Populate schedule_residents from old residents table
    execute """
    INSERT INTO schedule_residents
      (resident_id, schedule_id, position_code, residency_year, schedule_number, calendar_token, inserted_at, updated_at)
    SELECT r.id, rpo.schedule_id, rpo.position_code, rpo.residency_year, rpo.schedule_number, rpo.calendar_token, rpo.inserted_at, rpo.updated_at
    FROM resident_positions_old rpo
    JOIN residents r ON r.name = rpo.name
    """

    # 6. Add schedule_resident_id to rotations (nullable while we populate it)
    alter table(:rotations) do
      add :schedule_resident_id, :bigint
    end

    # 7. Populate schedule_resident_id
    execute """
    UPDATE rotations rot
    SET schedule_resident_id = sr.id
    FROM resident_positions_old rpo
    JOIN schedule_residents sr ON sr.schedule_id = rpo.schedule_id AND sr.position_code = rpo.position_code
    WHERE rot.resident_id = rpo.id
    """

    # 8. Make schedule_resident_id NOT NULL, add FK, drop old column
    alter table(:rotations) do
      modify :schedule_resident_id, :bigint, null: false
      remove :resident_id
    end

    execute """
    ALTER TABLE rotations
    ADD CONSTRAINT rotations_schedule_resident_id_fkey
    FOREIGN KEY (schedule_resident_id) REFERENCES schedule_residents(id) ON DELETE CASCADE
    """

    create index(:rotations, [:schedule_resident_id])
    create index(:rotations, [:schedule_resident_id, :start_date])

    # 9. Add covering_schedule_resident_id to shift_overrides
    alter table(:shift_overrides) do
      add :covering_schedule_resident_id, :bigint
    end

    # 10. Populate covering_schedule_resident_id
    execute """
    UPDATE shift_overrides so
    SET covering_schedule_resident_id = sr.id
    FROM resident_positions_old rpo
    JOIN schedule_residents sr ON sr.schedule_id = rpo.schedule_id AND sr.position_code = rpo.position_code
    WHERE so.covering_resident_id = rpo.id
    """

    # 11. Make covering_schedule_resident_id NOT NULL, add FK, drop old column
    alter table(:shift_overrides) do
      modify :covering_schedule_resident_id, :bigint, null: false
      remove :covering_resident_id
    end

    execute """
    ALTER TABLE shift_overrides
    ADD CONSTRAINT shift_overrides_covering_schedule_resident_id_fkey
    FOREIGN KEY (covering_schedule_resident_id) REFERENCES schedule_residents(id) ON DELETE CASCADE
    """

    create index(:shift_overrides, [:covering_schedule_resident_id])

    # 12. Drop the old temporary table
    drop table(:resident_positions_old)
  end

  def down do
    raise Ecto.MigrationError, message: "This migration cannot be reversed automatically"
  end
end
