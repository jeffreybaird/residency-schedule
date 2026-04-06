defmodule ResidencySchedule.Repo.Migrations.CreateUsersAndMagicLinkTokens do
  use Ecto.Migration

  def change do
    execute "CREATE EXTENSION IF NOT EXISTS citext", "SELECT 1"

    create table(:users) do
      add :email, :citext, null: false
      add :password_hash, :string
      add :approved, :boolean, default: false, null: false
      add :home_resident_id, references(:schedule_residents, on_delete: :nilify_all)

      timestamps(type: :utc_datetime)
    end

    create unique_index(:users, [:email])
    create index(:users, [:home_resident_id])

    create table(:magic_link_tokens) do
      add :token, :string, null: false
      add :expires_at, :utc_datetime, null: false
      add :used_at, :utc_datetime
      add :user_id, references(:users, on_delete: :delete_all), null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:magic_link_tokens, [:token])
    create index(:magic_link_tokens, [:user_id])
  end
end
