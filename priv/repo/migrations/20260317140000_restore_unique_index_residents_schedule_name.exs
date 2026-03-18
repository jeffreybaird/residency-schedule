defmodule ResidencySchedule.Repo.Migrations.RestoreUniqueIndexResidentsScheduleName do
  use Ecto.Migration

  def change do
    create unique_index(:residents, [:schedule_id, :name])
  end
end
