defmodule ResidencySchedule.Repo.Migrations.CreateChatDailyUsage do
  use Ecto.Migration

  def change do
    create table(:chat_daily_usage) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :date, :date, null: false
      add :messages, :integer, null: false, default: 0
      timestamps(type: :utc_datetime)
    end

    create unique_index(:chat_daily_usage, [:user_id, :date])
  end
end
