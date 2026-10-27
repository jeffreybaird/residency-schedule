defmodule ResidencySchedule.TaskMappings.Classification do
  @moduledoc "An initial interpretation of one saved source occurrence, preserving its inputs."
  use Ecto.Schema

  schema "activity_source_classifications" do
    field :original_source_id, :integer
    belongs_to :activity_source, ResidencySchedule.DetailedSchedules.ActivitySource
    field :namespace, :string
    field :source_snapshot, :map, default: %{}
    field :mapping_snapshot, :map, default: %{}
    field :input_digest, :string
    belongs_to :mapping, ResidencySchedule.TaskMappings.Mapping
    field :mapping_revision, :integer
    field :rule_version, :string
    field :status, :string
    field :activity_type_code, :string
    field :evidence_origin, :string
    timestamps(type: :utc_datetime)
  end
end
