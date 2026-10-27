defmodule ResidencySchedule.Repo.Migrations.AddSourceIdentityMappings do
  use Ecto.Migration

  def up, do: Enum.each(up_sql(), &execute/1)
  def down, do: Enum.each(down_sql(), &execute/1)

  @doc """
  Returns the additive identity evidence schema statements.

      iex> is_list(ResidencySchedule.Repo.Migrations.AddSourceIdentityMappings.up_sql())
      true
  """
  def up_sql do
    [
      "CREATE UNIQUE INDEX identity_mapping_membership_scope ON schedule_residents (id, schedule_id)",
      """
      CREATE TABLE source_identity_mappings (
        id bigserial PRIMARY KEY,
        scope_schedule_id bigint NOT NULL CHECK (scope_schedule_id > 0),
        schedule_id bigint REFERENCES schedules(id) ON DELETE SET NULL,
        schedule_resident_id bigint REFERENCES schedule_residents(id) ON DELETE SET NULL,
        namespace text NOT NULL CHECK (namespace IN ('csv', 'qgenda')),
        source_key text NOT NULL CHECK (octet_length(source_key) BETWEEN 1 AND 512),
        lookup_key text NOT NULL CHECK (octet_length(lookup_key) BETWEEN 1 AND 512),
        normalization_version text NOT NULL,
        target_snapshot jsonb NOT NULL,
        revision integer NOT NULL CHECK (revision > 0),
        status text NOT NULL CHECK (status IN ('observed', 'approved')),
        current boolean NOT NULL DEFAULT false,
        evidence_origin text NOT NULL,
        evidence_source_id bigint REFERENCES detailed_activity_sources(id) ON DELETE SET NULL,
        evidence_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
        approved_by_id bigint REFERENCES users(id) ON DELETE SET NULL,
        actor_snapshot jsonb NOT NULL DEFAULT '{}'::jsonb,
        inserted_at timestamp(0) without time zone NOT NULL,
        updated_at timestamp(0) without time zone NOT NULL,
        CONSTRAINT identity_mapping_scope CHECK (schedule_id IS NULL OR schedule_id = scope_schedule_id),
        CONSTRAINT identity_mapping_current CHECK (NOT current OR status = 'approved'),
        CONSTRAINT identity_mapping_normalization CHECK (
          (namespace = 'csv' AND normalization_version = 'csv_alias_v1') OR
          (namespace = 'qgenda' AND normalization_version = 'qgenda_full_name_v1')
        ),
        CONSTRAINT identity_mapping_origin CHECK (
          (status = 'observed' AND evidence_origin = 'activity_source') OR
          (status = 'approved' AND evidence_origin = 'reviewed_crosswalk')
        ),
        CONSTRAINT identity_mapping_membership FOREIGN KEY (schedule_resident_id, schedule_id)
          REFERENCES schedule_residents(id, schedule_id)
          ON DELETE SET NULL (schedule_resident_id)
      )
      """,
      "CREATE UNIQUE INDEX identity_mapping_current ON source_identity_mappings (scope_schedule_id, namespace, lookup_key) WHERE current AND status = 'approved'",
      "CREATE UNIQUE INDEX identity_mapping_observation ON source_identity_mappings (evidence_source_id) WHERE status = 'observed'",
      "CREATE UNIQUE INDEX identity_mapping_revision ON source_identity_mappings (scope_schedule_id, namespace, lookup_key, revision)",
      "CREATE INDEX identity_mapping_lookup ON source_identity_mappings (scope_schedule_id, namespace, lookup_key)"
    ]
  end

  @doc """
  Removes the new table and its supporting membership index.

      iex> length(ResidencySchedule.Repo.Migrations.AddSourceIdentityMappings.down_sql())
      2
  """
  def down_sql,
    do: ["DROP TABLE source_identity_mappings", "DROP INDEX identity_mapping_membership_scope"]
end
