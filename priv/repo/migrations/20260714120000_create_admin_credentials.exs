defmodule ResidencySchedule.Repo.Migrations.CreateAdminCredentials do
  use Ecto.Migration

  def change do
    create table(:admin_credentials) do
      add :password_hash, :string, null: false

      timestamps(type: :utc_datetime)
    end
  end
end
