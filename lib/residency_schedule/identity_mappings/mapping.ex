defmodule ResidencySchedule.IdentityMappings.Mapping do
  @moduledoc "Persistent identity evidence. Historical fields are written once by the context."
  use Ecto.Schema

  schema "source_identity_mappings" do
    field :scope_schedule_id, :integer
    belongs_to :schedule, ResidencySchedule.Schedules.Schedule
    belongs_to :schedule_resident, ResidencySchedule.Residents.ScheduleResident
    field :namespace, :string
    field :source_key, :string
    field :lookup_key, :string
    field :normalization_version, :string
    field :target_snapshot, :map
    field :revision, :integer
    field :status, :string
    field :current, :boolean, default: false
    field :evidence_origin, :string
    belongs_to :evidence_source, ResidencySchedule.DetailedSchedules.ActivitySource
    field :evidence_snapshot, :map, default: %{}
    belongs_to :approved_by, ResidencySchedule.Accounts.User
    field :actor_snapshot, :map, default: %{}
    timestamps(type: :utc_datetime)
  end
end
