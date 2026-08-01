defmodule ResidencySchedule.Release do
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
    |> ResidencySchedule.Importer.ScheduleImporter.import_csv()
  end

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
