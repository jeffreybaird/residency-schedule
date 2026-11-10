defmodule ResidencySchedule.Repo.Migrations.AddFridayPolicyAttestations do
  use Ecto.Migration

  def up, do: Enum.each(up_sql(), &execute/1)
  def down, do: Enum.each(down_sql(), &execute/1)

  @doc """
  Returns additive policy-attestation statements without rewriting classifications.

      iex> length(ResidencySchedule.Repo.Migrations.AddFridayPolicyAttestations.up_sql())
      2
  """
  def up_sql do
    [
      "CREATE UNIQUE INDEX friday_attestation_classification_anchor ON activity_source_classifications (id,original_source_id,input_digest,mapping_id,namespace,mapping_revision,rule_version)",
      """
      CREATE TABLE friday_policy_attestations (
        id bigserial PRIMARY KEY,
        classification_id bigint NOT NULL UNIQUE,
        original_source_id bigint NOT NULL CHECK (original_source_id > 0),
        original_input_digest text NOT NULL,
        original_mapping_id bigint NOT NULL,
        namespace text NOT NULL CHECK (namespace='qgenda'),
        original_mapping_revision integer NOT NULL CHECK (original_mapping_revision > 0),
        original_rule_version text NOT NULL CHECK (original_rule_version='legacy_task_classification_v1'),
        rule_version text NOT NULL CHECK (rule_version='legacy_task_classification_v2'),
        policy text NOT NULL CHECK (policy='friday_strong_correction_v1'),
        status text NOT NULL CHECK (status='context_required'),
        target_codes text[] NOT NULL CHECK (target_codes=ARRAY['night_float','strong_weekend_nights']::text[]),
        evidence_origin text NOT NULL CHECK (evidence_origin='legacy_code'),
        policy_fingerprint text NOT NULL CHECK (length(policy_fingerprint)=64),
        original_semantics jsonb NOT NULL,
        source_anchor jsonb NOT NULL,
        mapping_anchor jsonb NOT NULL,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL,
        CONSTRAINT friday_attestation_original_class FOREIGN KEY
          (classification_id,original_source_id,original_input_digest,original_mapping_id,namespace,original_mapping_revision,original_rule_version)
          REFERENCES activity_source_classifications
          (id,original_source_id,input_digest,mapping_id,namespace,mapping_revision,rule_version) ON DELETE RESTRICT,
        CONSTRAINT friday_attestation_original_mapping FOREIGN KEY
          (original_mapping_id,namespace,original_mapping_revision,original_rule_version)
          REFERENCES source_task_mappings(id,namespace,revision,rule_version) ON DELETE RESTRICT
      )
      """
    ]
  end

  @doc """
  Removes only the additive attestation table and supporting index.

      iex> hd(ResidencySchedule.Repo.Migrations.AddFridayPolicyAttestations.down_sql())
      "DROP TABLE friday_policy_attestations"
  """
  def down_sql,
    do: [
      "DROP TABLE friday_policy_attestations",
      "DROP INDEX friday_attestation_classification_anchor"
    ]
end
