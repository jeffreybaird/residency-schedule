defmodule ResidencySchedule.Repo.Migrations.RunPhase2Backfills do
  @moduledoc """
  Runs the four Phase 2 backfills once during `ResidencySchedule.Release.migrate/0`.

  The migration is one-shot, idempotent and additive: it fills empty QGenda
  source references, observes resident identity keys, seeds the legacy task
  facts and classifies saved occurrences, then records timing precision. It
  never updates or deletes an existing backfilled row, so rerunning the matching
  `ResidencySchedule.Release.backfill_*` command afterwards is the documented
  verification and reports zero new rows.

  The DDL transaction and migration lock are disabled because each backfill
  already commits one bounded transaction per batch under its own write lock.
  Wrapping every batch in a single outer transaction would hold the migration
  lock for the whole run, make the earlier completed batches roll back on a
  later failure, and remove the "interrupted work can be rerun" guarantee the
  backfills provide. A step failure still stops `Release.migrate/0`.

  `up/0` honours the `:run_phase2_backfills_on_migrate` application setting
  (default `true`, `false` in `config/test.exs`), so test databases are never
  seeded by migration; the test suite seeds per sandbox instead. `run/0` ignores
  the flag.
  """
  use Ecto.Migration

  require Logger

  alias ResidencySchedule.{IdentityMappings, SourceProvenance, TaskMappings, Timings}

  @disable_ddl_transaction true
  @disable_migration_lock true

  def up do
    if Application.get_env(:residency_schedule, :run_phase2_backfills_on_migrate, true) do
      run_or_raise()
    else
      Logger.info("Phase 2 backfill skipped: run_phase2_backfills_on_migrate is false")
      :ok
    end
  end

  defp run_or_raise do
    case run() do
      {:ok, _counts} ->
        :ok

      {:error, {step, reason}} ->
        raise "Phase 2 backfill failed: #{inspect(step)} #{inspect(reason)}"
    end
  end

  def down, do: :ok

  @doc """
  Executes the backfills in order, stopping at the first failing step.

  Returns the counts of every step, or `{:error, {step, reason}}` for the step
  that failed. Only aggregate counts are logged.

      iex> _ctx = ResidencySchedule.TimingDoctestFixtures.source()
      iex> {:ok, result} = ResidencySchedule.Repo.Migrations.RunPhase2Backfills.run()
      iex> {result.timings.processed, result.task_classifications.classifications.resolved}
      {1, 1}
  """
  def run do
    with {:ok, provenance} <- step(:source_provenance, &SourceProvenance.backfill/0),
         {:ok, identities} <- step(:identity_mappings, &IdentityMappings.backfill/0),
         {:ok, classifications} <- step(:task_classifications, &classify_tasks/0),
         {:ok, timings} <- step(:timings, &Timings.backfill/0) do
      {:ok,
       %{
         source_provenance: provenance,
         identity_mappings: identities,
         task_classifications: classifications,
         timings: timings
       }}
    end
  end

  defp classify_tasks do
    with {:ok, seed} <- TaskMappings.seed_legacy(),
         {:ok, classifications} <- TaskMappings.backfill() do
      {:ok, %{seed: seed, classifications: classifications}}
    end
  end

  defp step(name, backfill) do
    case backfill.() do
      {:ok, counts} ->
        Logger.info("Phase 2 backfill #{name} completed: #{inspect(counts)}")
        {:ok, counts}

      {:error, reason} ->
        Logger.info("Phase 2 backfill #{name} failed")
        {:error, {name, reason}}
    end
  end
end
