defmodule ResidencySchedule.Repo.Migrations.CreateShiftOverrides do
  use Ecto.Migration

  def change do
    create table(:shift_overrides) do
      add :rotation_id, references(:rotations, on_delete: :delete_all), null: false
      add :covering_resident_id, references(:residents, on_delete: :delete_all), null: false
      add :override_start_date, :date, null: false
      add :override_end_date, :date, null: false
      timestamps(type: :utc_datetime)
    end

    create index(:shift_overrides, [:rotation_id])
    create index(:shift_overrides, [:covering_resident_id])
  end
end
