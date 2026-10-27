defmodule ResidencySchedule.Repo.Migrations.AddTaskClassifications do
  use Ecto.Migration

  def up, do: Enum.each(up_sql(), &execute/1)
  def down, do: Enum.each(down_sql(), &execute/1)

  @doc """
  Returns the additive catalogue, mapping and source-result schema.

      iex> length(ResidencySchedule.Repo.Migrations.AddTaskClassifications.up_sql()) > 4
      true
  """
  def up_sql do
    [
      """
      CREATE TABLE activity_types (
        id bigserial PRIMARY KEY,
        code text NOT NULL UNIQUE CHECK (code NOT IN ('unknown', 'qgenda_assignment') AND octet_length(code) BETWEEN 1 AND 128),
        label text NOT NULL,
        description text NOT NULL,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL
      )
      """,
      """
      CREATE TABLE source_task_mappings (
        id bigserial PRIMARY KEY,
        namespace text NOT NULL CHECK (namespace IN ('csv','qgenda')),
        source_label text NOT NULL CHECK (octet_length(source_label) BETWEEN 1 AND 512),
        lookup_key text NOT NULL CHECK (octet_length(lookup_key) BETWEEN 1 AND 512),
        normalization_version text NOT NULL,
        revision integer NOT NULL CHECK (revision > 0),
        current boolean NOT NULL DEFAULT true,
        recognized boolean NOT NULL DEFAULT false,
        evidence_origin text NOT NULL CHECK (evidence_origin IN ('legacy_code','reviewed','custom')),
        rule_version text NOT NULL,
        policy text NOT NULL,
        evidence_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL,
        CONSTRAINT task_mapping_normalization CHECK (
          (namespace='csv' AND normalization_version='csv_abbreviation_v1') OR
          (namespace='qgenda' AND normalization_version='qgenda_exact_v1')
        ),
        UNIQUE (namespace,lookup_key,revision),
        UNIQUE (id,namespace,revision,rule_version)
      )
      """,
      "CREATE UNIQUE INDEX task_mapping_current ON source_task_mappings(namespace,lookup_key) WHERE current",
      """
      CREATE TABLE source_task_mapping_targets (
        mapping_id bigint NOT NULL REFERENCES source_task_mappings(id),
        activity_type_code text NOT NULL REFERENCES activity_types(code),
        PRIMARY KEY(mapping_id,activity_type_code)
      )
      """,
      """
      CREATE TABLE activity_source_classifications (
        id bigserial PRIMARY KEY,
        original_source_id bigint NOT NULL UNIQUE CHECK (original_source_id > 0),
        activity_source_id bigint REFERENCES detailed_activity_sources(id) ON DELETE SET NULL,
        namespace text NOT NULL CHECK (namespace IN ('csv','qgenda')),
        source_snapshot jsonb NOT NULL,
        mapping_snapshot jsonb NOT NULL,
        input_digest text NOT NULL,
        mapping_id bigint,
        mapping_revision integer,
        rule_version text NOT NULL,
        status text NOT NULL CHECK (status IN ('resolved','context_required','recognized_unclassified','unmapped','conflicting')),
        activity_type_code text,
        evidence_origin text NOT NULL CHECK (evidence_origin IN ('legacy_code','reviewed','custom')),
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL,
        CONSTRAINT task_classification_live_source CHECK (activity_source_id IS NULL OR activity_source_id=original_source_id),
        CONSTRAINT task_classification_resolution CHECK (
          (status='resolved' AND activity_type_code IS NOT NULL AND mapping_id IS NOT NULL) OR
          (status<>'resolved' AND activity_type_code IS NULL)
        ),
        CONSTRAINT task_classification_revision CHECK (
          (mapping_id IS NULL AND mapping_revision IS NULL) OR
          (mapping_id IS NOT NULL AND mapping_revision IS NOT NULL)
        ),
        CONSTRAINT task_classification_mapping FOREIGN KEY(mapping_id,namespace,mapping_revision,rule_version)
          REFERENCES source_task_mappings(id,namespace,revision,rule_version),
        CONSTRAINT task_classification_target FOREIGN KEY(mapping_id,activity_type_code)
          REFERENCES source_task_mapping_targets(mapping_id,activity_type_code)
      )
      """,
      "CREATE INDEX task_classification_mapping_index ON activity_source_classifications(mapping_id)"
    ]
  end

  @doc """
  Removes only the additive task interpretation representation.

      iex> hd(ResidencySchedule.Repo.Migrations.AddTaskClassifications.down_sql())
      "DROP TABLE activity_source_classifications"
  """
  def down_sql do
    [
      "DROP TABLE activity_source_classifications",
      "DROP TABLE source_task_mapping_targets",
      "DROP TABLE source_task_mappings",
      "DROP TABLE activity_types"
    ]
  end
end
