defmodule ResidencySchedule.Release do
  @moduledoc "Provides database tasks for application releases."

  alias Ecto.Adapters.SQL
  alias ResidencySchedule.IdentityMappings
  alias ResidencySchedule.Importer.ScheduleImporter
  alias ResidencySchedule.SourceProvenance
  alias ResidencySchedule.StagingFixtures
  @app :residency_schedule

  @doc """
  Runs all pending migrations. Called from the deploy script before service restart.
  Does not require the Mix toolchain — safe to call from a compiled release.

      iex> is_function(&ResidencySchedule.Release.migrate/0)
      true
  """
  def migrate do
    load_app()

    for repo <- repos() do
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end
  end

  @doc """
  Rolls back a specific migration version for a given repo.

      iex> is_function(&ResidencySchedule.Release.rollback/2)
      true
  """
  def rollback(repo, version) do
    load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @doc """
  Promotes the user with the given email to the admin role (approving them in
  the process). Bootstrap path for the first admin on a fresh deploy, callable
  from a compiled release:

      bin/residency_schedule eval 'ResidencySchedule.Release.promote_admin("me@example.com")'

  Returns `{:ok, user}` or `{:error, :not_found}` when no account has that email.

      iex> is_function(&ResidencySchedule.Release.promote_admin/1)
      true
  """
  def promote_admin(email) do
    load_app()
    [repo] = repos()

    {:ok, result, _apps} =
      Ecto.Migrator.with_repo(repo, fn _repo -> promote_admin_by_email(email) end)

    result
  end

  defp promote_admin_by_email(email) do
    case ResidencySchedule.Accounts.get_user_by_email(email) do
      nil -> {:error, :not_found}
      user -> ResidencySchedule.Accounts.set_role(user, :admin)
    end
  end

  @doc """
  Imports the synthetic demo schedule shipped in `priv/demo/demo_schedule.csv`.

  Called by the deploy script on demo deployments only. Re-running it replaces
  the demo academic year in place, so it is safe on every deploy.

  Doctest omitted: this writes to the database; see the integration test.
  """
  def seed_demo do
    load_app()
    [repo] = repos()

    {:ok, result, _apps} = Ecto.Migrator.with_repo(repo, fn _repo -> import_demo_csv() end)

    result
  end

  @doc """
  Backfills generic source references using retained QGenda coordinates.

  Callable after migration from a compiled release:

      bin/residency_schedule eval 'IO.inspect(ResidencySchedule.Release.backfill_source_provenance())'

  Repeating the call preserves populated references. Requires a database; covered
  by integration tests instead of doctests.
  """
  def backfill_source_provenance do
    load_app()
    [repo] = repos()

    {:ok, result, _apps} =
      Ecto.Migrator.with_repo(repo, fn _repo -> SourceProvenance.backfill() end)

    result
  end

  @doc """
  Records existing QGenda associations as observed identity evidence only.

  Run after migration and print the bounded, repeatable operation's counts:

      bin/residency_schedule eval 'IO.inspect(ResidencySchedule.Release.backfill_identity_mappings())'

  The explicit synthetic fixture runs this example in the test database sandbox.

      iex> _ctx = ResidencySchedule.IdentityMappingDoctestFixtures.with_source()
      iex> ResidencySchedule.Release.backfill_identity_mappings()
      {:ok, %{observations_added: 1, unchanged: 0, conflicting_keys: 0}}
  """
  def backfill_identity_mappings do
    load_app()
    [repo] = repos()

    {:ok, result, _apps} =
      Ecto.Migrator.with_repo(repo, fn _repo -> IdentityMappings.backfill() end)

    result
  end

  @doc """
  Manually seeds persistent synthetic staging fixtures after checking the actual
  connected database and both staging declarations. Never called by deployment.

  Requires a database; guarded behavior is covered by integration tests.
  """
  def seed_staging do
    load_app()
    [repo] = repos()

    {:ok, result, _apps} =
      Ecto.Migrator.with_repo(repo, fn repo ->
        %{rows: [[database]]} = SQL.query!(repo, "SELECT current_database()", [])

        with :ok <-
               StagingFixtures.validate_target(
                 System.get_env("CONFIG_ENVIRONMENT"),
                 System.get_env("EXPECTED_DATABASE_NAME"),
                 database
               ) do
          StagingFixtures.seed()
        end
      end)

    result
  end

  @doc """
  Returns the absolute path to the demo CSV inside the release.

      iex> ResidencySchedule.Release.demo_csv_path() =~ "demo_schedule.csv"
      true
  """
  def demo_csv_path do
    Application.app_dir(@app, "priv/demo/demo_schedule.csv")
  end

  defp import_demo_csv do
    demo_csv_path()
    |> File.read!()
    |> ScheduleImporter.import_csv()
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
