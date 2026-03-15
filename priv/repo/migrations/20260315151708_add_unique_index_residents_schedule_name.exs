defmodule ResidencySchedule.Repo.Migrations.AddUniqueIndexResidentsScheduleName do
  use Ecto.Migration

  def up do
    # Remove duplicate residents, keeping the lowest id for each (schedule_id, name) pair.
    # Rotations are cascade-deleted via the FK on_delete: :delete_all constraint.
    execute """
    DELETE FROM residents
    WHERE id NOT IN (
      SELECT MIN(id)
      FROM residents
      GROUP BY schedule_id, name
    )
    """

    create unique_index(:residents, [:schedule_id, :name])
  end

  def down do
    drop unique_index(:residents, [:schedule_id, :name])
  end
end
