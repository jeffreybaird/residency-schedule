defmodule ResidencySchedule.ScheduleCache.Revision do
  @moduledoc "Transactional generation for all data contributing to the shared schedule grid."

  alias Ecto.Adapters.SQL
  alias ResidencySchedule.Repo

  @doc "Reads the committed generation. Exempt from doctest — database integration tests."
  def current do
    %{rows: [[revision]]} =
      SQL.query!(
        Repo.get_dynamic_repo(),
        "SELECT revision FROM schedule_cache_revision WHERE id = 1",
        []
      )

    revision
  end

  @doc """
  Acquires the generation lock before other locks in a schedule write transaction.

  The transaction-local suppression flag is set only by SQL Sandbox test setup;
  sandbox reads unconditionally bypass the cache. Production does not set it.
  Exempt from doctest — integration tests exercise transaction lock ordering.
  """
  def lock do
    SQL.query!(
      Repo.get_dynamic_repo(),
      """
      SELECT revision FROM schedule_cache_revision
      WHERE id = 1
        AND current_setting('residency_schedule.skip_cache_revision', true) IS DISTINCT FROM 'on'
      FOR UPDATE
      """,
      []
    )

    :ok
  end
end
