defmodule ResidencySchedule.Repo.Migrations.CreateResidents do
  use Ecto.Migration

  def change do
    create table(:residents) do
      add :schedule_id, references(:schedules, on_delete: :delete_all), null: false
      add :position_code, :string, null: false
      add :residency_year, :integer, null: false
      add :schedule_number, :integer, null: false
      add :name, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:residents, [:schedule_id, :position_code])
    create index(:residents, [:schedule_id, :residency_year, :schedule_number])
  end
end
