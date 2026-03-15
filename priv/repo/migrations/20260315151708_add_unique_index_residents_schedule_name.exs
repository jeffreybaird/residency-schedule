defmodule ResidencySchedule.Repo.Migrations.AddUniqueIndexResidentsScheduleName do
  use Ecto.Migration

  def change do
    create index(:residents, [:schedule_id, :name])
  end
end
