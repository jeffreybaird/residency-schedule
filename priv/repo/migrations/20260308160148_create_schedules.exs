defmodule ResidencySchedule.Repo.Migrations.CreateSchedules do
  use Ecto.Migration

  def change do
    create table(:schedules) do
      add :academic_year, :integer, null: false
      add :label, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:schedules, [:academic_year])
  end
end
