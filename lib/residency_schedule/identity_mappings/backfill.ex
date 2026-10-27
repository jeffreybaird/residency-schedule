defmodule ResidencySchedule.IdentityMappings.Backfill do
  @moduledoc false
  import Ecto.Query

  alias Ecto.Adapters.SQL
  alias ResidencySchedule.DetailedSchedules.{Activity, ActivitySource, ImportBatch}
  alias ResidencySchedule.IdentityMappings.{Key, Mapping, State}
  alias ResidencySchedule.Repo
  alias ResidencySchedule.Residents.{Resident, ScheduleResident}
  alias ResidencySchedule.ScheduleCache.Revision

  @doc """
  Retains historical associations as observations only, in bounded batches.

      iex> ctx = ResidencySchedule.IdentityMappingDoctestFixtures.with_source()
      iex> ResidencySchedule.IdentityMappings.Backfill.run(batch_size: 1)
      {:ok, %{observations_added: 1, unchanged: 0, conflicting_keys: 0}}
      iex> {:ok, result} = ResidencySchedule.IdentityMappings.resolve(ctx.schedule.id, :qgenda, "Legacy Iris")
      iex> {result.status, result.reason}
      {:held, :observed_only}
  """
  def run(options) do
    with {:ok, batch_size} <- validate_options(options),
         {:ok, counts} <- fill_pages(0, batch_size, %{observations_added: 0, unchanged: 0}) do
      {:ok, Map.put(counts, :conflicting_keys, conflicting_keys())}
    end
  rescue
    _error in [Postgrex.Error, Ecto.ConstraintError] -> {:error, :retryable}
  end

  defp validate_options(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.all?(Keyword.keys(options), &(&1 == :batch_size)) do
      case Keyword.get(options, :batch_size, 500) do
        size when is_integer(size) and size in 1..1000 -> {:ok, size}
        _ -> {:error, :invalid_batch_size}
      end
    else
      {:error, :invalid_batch_size}
    end
  end

  defp validate_options(_options), do: {:error, :invalid_batch_size}

  defp fill_pages(after_id, batch_size, counts) do
    ids =
      eligible_sources()
      |> where([source], source.id > ^after_id)
      |> order_by([source], source.id)
      |> limit(^batch_size)
      |> select([source], source.id)
      |> Repo.all()

    case ids do
      [] ->
        {:ok, counts}

      _ ->
        with {:ok, next_counts} <- fill_batch(ids, counts) do
          fill_pages(List.last(ids), batch_size, next_counts)
        end
    end
  end

  defp eligible_sources do
    from source in ActivitySource,
      join: batch in ImportBatch,
      on: batch.id == source.batch_id,
      where: batch.source_kind == "qgenda"
  end

  defp fill_batch(ids, counts) do
    Repo.transaction(fn ->
      Revision.lock()

      ids
      |> retained_sources()
      |> Enum.reduce(counts, &retain_source/2)
    end)
  end

  defp retained_sources(ids) do
    eligible_sources()
    |> join(:inner, [source], activity in Activity, on: activity.id == source.activity_id)
    |> join(:inner, [_source, _batch, activity], member in ScheduleResident,
      on: member.id == activity.schedule_resident_id
    )
    |> join(:inner, [_source, _batch, _activity, member], person in Resident,
      on: person.id == member.resident_id
    )
    |> where([source], source.id in ^ids)
    |> order_by([source], source.id)
    |> select([source, batch, _activity, member, person], %{
      source: source,
      batch_schedule_id: batch.schedule_id,
      member: %{member | name: person.name}
    })
    |> Repo.all()
  end

  defp retain_source(%{source: source, member: member, batch_schedule_id: scope}, counts) do
    if scope != member.schedule_id, do: Repo.rollback(:inconsistent_source_scope)

    case Key.normalize(:qgenda, source.raw_staff) do
      {:ok, key} -> retain_valid_source(source, member, key, counts)
      {:error, :invalid_source_key} -> counts
    end
  end

  defp retain_valid_source(source, member, key, counts) do
    exists =
      Repo.exists?(
        from m in Mapping, where: m.evidence_source_id == ^source.id and m.status == "observed"
      )

    if exists do
      Map.update!(counts, :unchanged, &(&1 + 1))
    else
      Repo.insert!(%Mapping{
        scope_schedule_id: member.schedule_id,
        schedule_id: member.schedule_id,
        schedule_resident_id: member.id,
        namespace: "qgenda",
        source_key: source.raw_staff,
        lookup_key: key.lookup_key,
        normalization_version: key.normalization_version,
        target_snapshot: State.snapshot(member),
        revision: State.next_revision(member.schedule_id, :qgenda, key.lookup_key),
        status: "observed",
        evidence_origin: "activity_source",
        evidence_source_id: source.id,
        evidence_snapshot: source_snapshot(source, member)
      })

      Map.update!(counts, :observations_added, &(&1 + 1))
    end
  end

  defp source_snapshot(source, member) do
    previous_name = source.previous_name || ""

    %{
      "source_id" => source.id,
      "batch_id" => source.batch_id,
      "raw_staff" => source.raw_staff,
      "previous_name" => source.previous_name,
      "historical_drift" => String.trim(previous_name) != "" and previous_name != member.name,
      "source_inserted_at" => source.inserted_at && DateTime.to_iso8601(source.inserted_at)
    }
  end

  defp conflicting_keys do
    %{rows: [[count]]} =
      SQL.query!(
        Repo,
        """
        SELECT count(*) FROM (
          SELECT scope_schedule_id, namespace, lookup_key
          FROM source_identity_mappings
          WHERE status = 'observed'
          GROUP BY scope_schedule_id, namespace, lookup_key
          HAVING count(DISTINCT (target_snapshot->>'schedule_resident_id', target_snapshot->>'resident_id')) > 1
        ) conflicts
        """,
        []
      )

    count
  end
end
