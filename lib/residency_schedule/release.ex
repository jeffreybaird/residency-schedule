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

  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  defp load_app do
    Application.load(@app)
  end
end
