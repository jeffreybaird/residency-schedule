defmodule ResidencySchedule.Repo.Migrations.AddSourceProvenance do
  use Ecto.Migration

  def up do
    Enum.each(up_sql(), &execute/1)
  end

  def down do
    Enum.each(down_sql(), &execute/1)
  end

  @doc """
  Returns the additive statements used by the migration.

      iex> length(ResidencySchedule.Repo.Migrations.AddSourceProvenance.up_sql())
      3
  """
  def up_sql do
    [
      """
      ALTER TABLE detailed_import_batches
        ADD COLUMN source_kind varchar(255) NOT NULL DEFAULT 'qgenda',
        ADD COLUMN source_metadata jsonb NOT NULL DEFAULT '{}'::jsonb
      """,
      """
      ALTER TABLE detailed_activity_sources
        ADD COLUMN source_reference jsonb NOT NULL DEFAULT '{}'::jsonb
      """,
      """
      ALTER TABLE rotations
        ADD COLUMN source_kind varchar(255) NOT NULL DEFAULT 'legacy',
        ADD COLUMN source_metadata jsonb NOT NULL DEFAULT '{}'::jsonb
      """
    ]
  end

  @doc """
  Returns statements that remove only this migration's added fields.

      iex> length(ResidencySchedule.Repo.Migrations.AddSourceProvenance.down_sql())
      3
  """
  def down_sql do
    [
      "ALTER TABLE rotations DROP COLUMN source_kind, DROP COLUMN source_metadata",
      "ALTER TABLE detailed_activity_sources DROP COLUMN source_reference",
      "ALTER TABLE detailed_import_batches DROP COLUMN source_kind, DROP COLUMN source_metadata"
    ]
  end
end
