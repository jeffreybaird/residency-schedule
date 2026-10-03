defmodule ResidencySchedule.Repo.Migrations.AddQgendaDetailedAssignments do
  use Ecto.Migration

  def change do
    create table(:detailed_import_batches) do
      add :schedule_id, references(:schedules, on_delete: :restrict), null: false
      add :created_by_id, references(:users, on_delete: :nilify_all)
      add :fingerprint, :string, null: false
      add :header_start, :date, null: false
      add :header_end, :date, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:detailed_import_batches, [:schedule_id, :fingerprint])

    create table(:detailed_activities) do
      add :schedule_resident_id, references(:schedule_residents, on_delete: :restrict),
        null: false

      add :date, :date, null: false
      add :raw_task, :text, null: false
      add :period, :string
      add :site, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:detailed_activities, [:schedule_resident_id, :date, :raw_task],
             name: :detailed_activity_identity
           )

    create index(:detailed_activities, [:date])

    create table(:detailed_activity_sources) do
      add :activity_id, references(:detailed_activities, on_delete: :delete_all), null: false
      add :batch_id, references(:detailed_import_batches, on_delete: :restrict), null: false
      add :source_sheet, :text, null: false
      add :source_cell, :string, null: false
      add :raw_staff, :text, null: false
      add :display_name, :text, null: false
      add :previous_name, :text, null: false
      add :notes, {:array, :map}, default: [], null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:detailed_activity_sources, [:batch_id, :source_sheet, :source_cell],
             name: :detailed_source_identity
           )

    create index(:detailed_activity_sources, [:activity_id])
  end
end
