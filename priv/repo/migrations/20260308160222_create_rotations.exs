defmodule ResidencySchedule.Repo.Migrations.CreateRotations do
  use Ecto.Migration

  def change do
    create table(:rotations) do
      add :resident_id, references(:residents, on_delete: :delete_all), null: false
      add :rotation_type, :string, null: false
      add :start_date, :date, null: false
      add :end_date, :date, null: false
      add :slot_index, :integer, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:rotations, [:resident_id])
    create index(:rotations, [:resident_id, :start_date])
    create index(:rotations, [:rotation_type])
  end
end
