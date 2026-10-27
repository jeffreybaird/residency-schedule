defmodule ResidencySchedule.IdentityMappings do
  @moduledoc """
  Additive, schedule-scoped resident identity evidence and reviewed aliases.

  Observations never authorize reusable aliases. Existing preview and import
  behavior remains authoritative; callers opt into this context explicitly.
  """

  alias ResidencySchedule.IdentityMappings.{Backfill, Crosswalk, Key, Resolver}

  @doc """
  Returns the bounded lookup key and its namespace-specific normalization version.

      iex> ResidencySchedule.IdentityMappings.normalize_key(:qgenda, " Reed, Iris ")
      {:ok, %{lookup_key: "iris reed", normalization_version: "qgenda_full_name_v1"}}

      iex> ResidencySchedule.IdentityMappings.normalize_key(:csv, " Reed, Iris ")
      {:ok, %{lookup_key: "reed, iris", normalization_version: "csv_alias_v1"}}
  """
  defdelegate normalize_key(namespace, source_key), to: Key, as: :normalize

  @doc """
  Resolves explicitly within one schedule and namespace, returning matched,
  unmatched, ambiguous or held, with a reason and any established target IDs.

  Database operation; integration tested instead of doctested.
  """
  defdelegate resolve(schedule_id, namespace, source_key), to: Resolver

  @doc """
  Prepares a read-only review of at most 1000 source_key/position_code/expected_name
  rows. Rechecks the actual persisted administrator, roster and retained evidence.

  Database operation; integration tested instead of doctested.
  """
  defdelegate prepare_crosswalk(schedule_id, namespace, rows, user), to: Crosswalk, as: :prepare

  @doc """
  Rechecks the administrator and full prepared state, then appends approvals in
  one transaction. Stale, held, conflicting or altered reviews write nothing.

  Database operation; integration tested instead of doctested.
  """
  defdelegate approve_crosswalk(plan, user), to: Crosswalk, as: :approve

  @doc """
  Backfills existing QGenda associations as observations, without relinking or
  changing source data. Batch size defaults to 500 and must be in 1..1000.

  A failed batch rolls back; earlier batches may remain and can be safely retried.
  Database operation; integration tested instead of doctested.
  """
  def backfill(options \\ []), do: Backfill.run(options)
end
