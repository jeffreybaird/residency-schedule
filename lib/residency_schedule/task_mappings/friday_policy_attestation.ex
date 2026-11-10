defmodule ResidencySchedule.TaskMappings.FridayPolicyAttestation do
  @moduledoc "Append-only code-origin policy evidence bound to one original classification."
  use Ecto.Schema

  schema "friday_policy_attestations" do
    belongs_to :classification, ResidencySchedule.TaskMappings.Classification
    field :original_source_id, :integer
    field :original_input_digest, :string
    field :original_mapping_id, :integer
    field :namespace, :string
    field :original_mapping_revision, :integer
    field :original_rule_version, :string
    field :rule_version, :string
    field :policy, :string
    field :status, :string
    field :target_codes, {:array, :string}
    field :evidence_origin, :string
    field :policy_fingerprint, :string
    field :original_semantics, :map
    field :source_anchor, :map
    field :mapping_anchor, :map
    timestamps(type: :utc_datetime)
  end
end
