defmodule ResidencySchedule.Repo.Migrations.PromoteInitialAdmin do
  use Ecto.Migration

  @admin_email "jeffreybaird@hey.com"

  # One-off data fix. The role-based auth cutover only promoted three @gmail
  # operator addresses to admin, so the primary operator account
  # (#{@admin_email}) was backfilled to a plain user and locked out of /admin.
  #
  # This upserts that account as an approved admin — create-if-missing, so it
  # works whether or not the person has logged in since the cutover. It is
  # skipped under the sandbox pool so the (non-truncating) test suite is not
  # polluted with a persistent admin row; promote_sql/0 is exercised directly by
  # an ExUnit test instead.
  def up do
    unless sandbox_repo?() do
      execute(promote_sql())
    end
  end

  def down do
    unless sandbox_repo?() do
      execute("UPDATE users SET role = 'user' WHERE email = '#{@admin_email}'")
    end
  end

  @doc """
  The upsert that promotes the operator account. `email` has a citext unique
  index, so `ON CONFLICT (email)` matches case-insensitively and an existing
  account (in any state) is promoted and approved rather than duplicated.
  """
  def promote_sql do
    """
    INSERT INTO users (email, role, approved, tour_completed, inserted_at, updated_at)
    VALUES ('#{@admin_email}', 'admin', true, false,
            date_trunc('second', now() at time zone 'utc'),
            date_trunc('second', now() at time zone 'utc'))
    ON CONFLICT (email) DO UPDATE
      SET role = 'admin',
          approved = true,
          updated_at = date_trunc('second', now() at time zone 'utc')
    """
  end

  defp sandbox_repo? do
    :residency_schedule
    |> Application.get_env(ResidencySchedule.Repo, [])
    |> Keyword.get(:pool) == Ecto.Adapters.SQL.Sandbox
  end
end
