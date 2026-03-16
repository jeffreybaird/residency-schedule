defmodule ResidencySchedule.Repo.Migrations.AddCalendarTokenToResidents do
  use Ecto.Migration

  def change do
    alter table(:residents) do
      add :calendar_token, :string
    end

    create unique_index(:residents, [:calendar_token])

    execute(
      "UPDATE residents SET calendar_token = md5(random()::text || clock_timestamp()::text || id::text) WHERE calendar_token IS NULL",
      ""
    )

    alter table(:residents) do
      modify :calendar_token, :string, null: false
    end
  end
end
