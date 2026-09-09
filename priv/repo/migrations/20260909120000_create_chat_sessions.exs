defmodule ResidencySchedule.Repo.Migrations.CreateChatSessions do
  use Ecto.Migration

  def change do
    create table(:chat_sessions) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :data, :map, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:chat_sessions, [:user_id])
  end
end
