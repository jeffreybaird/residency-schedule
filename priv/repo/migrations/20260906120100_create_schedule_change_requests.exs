defmodule ResidencySchedule.Repo.Migrations.CreateScheduleChangeRequests do
  use Ecto.Migration

  def change do
    create table(:schedule_change_requests) do
      add :rotation_id, references(:rotations, on_delete: :delete_all), null: false

      add :covering_schedule_resident_id,
          references(:schedule_residents, on_delete: :delete_all),
          null: false

      add :start_date, :date, null: false
      add :end_date, :date, null: false
      add :status, :string, null: false, default: "pending"
      add :note, :text
      add :requested_by_user_id, references(:users, on_delete: :delete_all), null: false
      add :reviewed_by_user_id, references(:users, on_delete: :nilify_all)
      add :reviewed_at, :utc_datetime
      add :review_note, :text
      add :shift_override_id, references(:shift_overrides, on_delete: :nilify_all)
      timestamps(type: :utc_datetime)
    end

    create index(:schedule_change_requests, [:rotation_id])
    create index(:schedule_change_requests, [:covering_schedule_resident_id])
    create index(:schedule_change_requests, [:requested_by_user_id])
    create index(:schedule_change_requests, [:status])
  end
end
