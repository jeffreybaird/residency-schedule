defmodule ResidencySchedule.TaskMappings.Mapping do
  @moduledoc "A retained revision of a source task's reviewed legacy meaning."
  use Ecto.Schema

  schema "source_task_mappings" do
    field :namespace, :string
    field :source_label, :string
    field :lookup_key, :string
    field :normalization_version, :string
    field :revision, :integer
    field :current, :boolean, default: true
    field :recognized, :boolean, default: false
    field :evidence_origin, :string
    field :rule_version, :string
    field :policy, :string
    field :evidence_snapshot, :map, default: %{}
    timestamps(type: :utc_datetime)
  end
end
