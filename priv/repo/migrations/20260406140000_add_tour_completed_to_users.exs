defmodule ResidencySchedule.Repo.Migrations.AddTourCompletedToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :tour_completed, :boolean, default: false, null: false
    end
  end
end
