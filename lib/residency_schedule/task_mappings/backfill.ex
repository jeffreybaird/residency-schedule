defmodule ResidencySchedule.TaskMappings.Backfill do
  @moduledoc false
  import Ecto.Query

  alias ResidencySchedule.DetailedSchedules.{Activity, ActivitySource, ImportBatch}
  alias ResidencySchedule.Repo
  alias ResidencySchedule.Residents.{Resident, ScheduleResident}
  alias ResidencySchedule.ScheduleCache.Revision
  alias ResidencySchedule.Schedules.Schedule
  alias ResidencySchedule.TaskMappings.{Classification, Classifier, Key, Mapping, Target}

  @doc """
  Records missing initial classifications without rewriting source facts.

      iex> _ctx = ResidencySchedule.TaskMappingDoctestFixtures.source()
      iex> {:ok, _seed} = ResidencySchedule.TaskMappings.seed_legacy()
      iex> {:ok, counts} = ResidencySchedule.TaskMappings.Backfill.run(batch_size: 1)
      iex> {counts.processed, counts.resolved, counts.conflicting}
      {1, 1, 0}
  """
  def run(options) do
    with {:ok, size} <- batch_size(options) do
      fill_pages(0, size, counts())
    end
  end

  defp counts do
    %{
      processed: 0,
      resolved: 0,
      context_required: 0,
      recognized_unclassified: 0,
      unmapped: 0,
      conflicting: 0,
      unchanged: 0
    }
  end

  defp batch_size(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.all?(Keyword.keys(options), &(&1 == :batch_size)) do
      case Keyword.get(options, :batch_size, 500) do
        size when is_integer(size) and size in 1..1000 -> {:ok, size}
        _ -> {:error, :invalid_batch_size}
      end
    else
      {:error, :invalid_batch_size}
    end
  end

  defp batch_size(_options), do: {:error, :invalid_batch_size}

  defp fill_pages(after_id, size, total) do
    ids =
      ActivitySource
      |> where([source], source.id > ^after_id)
      |> order_by([source], source.id)
      |> limit(^size)
      |> select([source], source.id)
      |> Repo.all()

    case ids do
      [] -> {:ok, total}
      _ -> fill_next(ids, size, total)
    end
  end

  defp fill_next(ids, size, total) do
    case Repo.transaction(fn -> fill_page(ids) end) do
      {:ok, page} ->
        updated = Map.merge(total, page, fn _key, previous, value -> previous + value end)
        fill_pages(List.last(ids), size, updated)

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fill_page(ids) do
    Revision.lock()

    ids
    |> source_rows()
    |> Enum.reduce(counts(), &fill_source/2)
  end

  defp source_rows(ids) do
    from(source in ActivitySource,
      join: activity in Activity,
      on: activity.id == source.activity_id,
      join: batch in ImportBatch,
      on: batch.id == source.batch_id,
      join: member in ScheduleResident,
      on: member.id == activity.schedule_resident_id,
      join: resident in Resident,
      on: resident.id == member.resident_id,
      join: schedule in Schedule,
      on: schedule.id == member.schedule_id,
      where: source.id in ^ids,
      order_by: source.id,
      lock: "FOR UPDATE",
      select: %{
        source: source,
        activity: activity,
        batch: batch,
        member: member,
        resident: resident,
        schedule: schedule
      }
    )
    |> Repo.all()
  end

  defp fill_source(row, totals) do
    namespace = validate_scope(row)

    existing =
      Classification
      |> where([result], result.original_source_id == ^row.source.id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    if existing && existing.evidence_origin != "legacy_code" do
      increment(totals, :unchanged)
    else
      fill_legacy(row, namespace, existing, totals)
    end
  end

  defp validate_scope(row) do
    if row.batch.schedule_id != row.member.schedule_id,
      do: Repo.rollback(:inconsistent_source_scope)

    namespace =
      case row.batch.source_kind do
        "csv" -> :csv
        "qgenda" -> :qgenda
        _ -> Repo.rollback(:unsupported_namespace)
      end

    case Key.normalize(namespace, row.activity.raw_task) do
      {:ok, _key} -> namespace
      {:error, _reason} -> Repo.rollback(:invalid_source_task)
    end
  end

  defp fill_legacy(row, namespace, existing, totals) do
    lock_mapping(namespace, row.activity.raw_task)

    result =
      case Classifier.classify(namespace, row.activity.raw_task) do
        {:ok, result} -> result
        {:error, reason} -> Repo.rollback(reason)
      end

    source = source_snapshot(row)
    mapping = Classifier.snapshot(result)
    digest = input_digest(source, mapping)

    cond do
      existing ->
        retained_result(existing, source, mapping, digest, totals)

      result.evidence_origin != "legacy_code" or result.status == :conflicting ->
        increment(totals, :conflicting)

      true ->
        insert_result(row.source.id, result, source, mapping, digest)
        totals |> increment(:processed) |> increment(result.status)
    end
  end

  defp lock_mapping(namespace, label) do
    {:ok, key} = Key.normalize(namespace, label)

    mapping =
      Mapping
      |> where([m], m.namespace == ^Atom.to_string(namespace) and m.lookup_key == ^key.lookup_key)
      |> where([m], m.current)
      |> lock("FOR UPDATE")
      |> Repo.one()

    if mapping do
      Target
      |> where([target], target.mapping_id == ^mapping.id)
      |> lock("FOR UPDATE")
      |> Repo.all()
    end
  end

  defp retained_result(existing, source, mapping, digest, totals) do
    if existing.input_digest == digest and existing.source_snapshot == source and
         existing.mapping_snapshot == mapping,
       do: increment(totals, :unchanged),
       else: increment(totals, :conflicting)
  end

  defp insert_result(id, result, source, mapping, digest) do
    Repo.insert!(%Classification{
      original_source_id: id,
      activity_source_id: id,
      namespace: result.namespace,
      source_snapshot: source,
      mapping_snapshot: mapping,
      input_digest: digest,
      mapping_id: result.mapping_id,
      mapping_revision: result.mapping_revision,
      rule_version: result.rule_version,
      status: Atom.to_string(result.status),
      activity_type_code: result.activity_type_code,
      evidence_origin: "legacy_code"
    })
  end

  defp source_snapshot(row) do
    %{
      source:
        Map.take(row.source, [
          :id,
          :activity_id,
          :batch_id,
          :source_sheet,
          :source_cell,
          :source_reference,
          :raw_staff,
          :display_name,
          :previous_name,
          :notes
        ]),
      activity:
        Map.take(row.activity, [:id, :schedule_resident_id, :date, :raw_task, :period, :site]),
      batch:
        Map.take(row.batch, [
          :id,
          :schedule_id,
          :created_by_id,
          :fingerprint,
          :source_kind,
          :source_metadata,
          :header_start,
          :header_end
        ]),
      member: Map.take(row.member, [:id, :schedule_id, :resident_id, :position_code]),
      resident: Map.take(row.resident, [:id, :name]),
      schedule: Map.take(row.schedule, [:id, :academic_year])
    }
    |> Jason.encode!()
    |> Jason.decode!()
  end

  defp input_digest(source, mapping) do
    {source, mapping}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp increment(counts, key), do: Map.update!(counts, key, &(&1 + 1))
end
