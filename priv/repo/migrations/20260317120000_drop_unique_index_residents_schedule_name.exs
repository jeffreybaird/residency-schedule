defmodule ResidencySchedule.Repo.Migrations.DropUniqueIndexResidentsScheduleName do
  use Ecto.Migration

  def change do
    drop_if_exists unique_index(:residents, [:schedule_id, :name])
  end
end
