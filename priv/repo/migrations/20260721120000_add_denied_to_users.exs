defmodule ResidencySchedule.Repo.Migrations.AddDeniedToUsers do
  use Ecto.Migration

  def change do
    alter table(:users) do
      add :denied, :boolean, default: false, null: false
    end
  end
end
