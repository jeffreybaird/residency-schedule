defmodule ResidencySchedule.Timings.Backfill do
  @moduledoc false
  import Ecto.Query

  alias ResidencySchedule.DetailedSchedules.{Activity, ActivitySource, ImportBatch}
  alias ResidencySchedule.Repo
  alias ResidencySchedule.ScheduleCache.Revision
  alias ResidencySchedule.Timings.{Interpreter, Timing}

  @rule_version "legacy_timing_v1"

  @doc """
  Records missing timing precision for saved sources from stored facts only.

      iex> _ctx = ResidencySchedule.TimingDoctestFixtures.source()
      iex> {:ok, counts} = ResidencySchedule.Timings.Backfill.run(batch_size: 1)
      iex> {counts.processed, counts.period, counts.conflicting}
      {1, 1, 0}
  """
  def run(options) do
    with {:ok, size} <- batch_size(options) do
      fill_pages(0, size, counts())
    end
  end

  defp counts do
    %{processed: 0, period: 0, date_only: 0, unchanged: 0, conflicting: 0}
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
      where: source.id in ^ids,
      order_by: source.id,
      lock: "FOR UPDATE",
      select: %{source: source, activity: activity, batch: batch}
    )
    |> Repo.all()
  end

  defp fill_source(row, totals) do
    namespace = validate_namespace(row.batch)

    existing =
      Timing
      |> where([timing], timing.original_source_id == ^row.source.id)
      |> lock("FOR UPDATE")
      |> Repo.one()

    cond do
      is_nil(existing) -> fill_missing(row, namespace, totals)
      existing.evidence_origin != "legacy_code" -> increment(totals, :unchanged)
      true -> retained_result(existing, row, totals)
    end
  end

  defp validate_namespace(%ImportBatch{source_kind: kind}) when kind in ["csv", "qgenda"],
    do: kind

  defp validate_namespace(_batch), do: Repo.rollback(:unsupported_namespace)

  defp retained_result(existing, row, totals) do
    if existing.rule_version == @rule_version and
         existing.input_digest == input_digest(source_snapshot(row.activity)),
       do: increment(totals, :unchanged),
       else: increment(totals, :conflicting)
  end

  defp fill_missing(row, namespace, totals) do
    case Interpreter.interpret(%{date: row.activity.date, period: row.activity.period}) do
      {:ok, result} ->
        insert_timing(row, namespace, result)
        totals |> increment(:processed) |> increment(result.precision)

      {:error, :unsupported_period} ->
        increment(totals, :conflicting)
    end
  end

  defp insert_timing(row, namespace, result) do
    snapshot = source_snapshot(row.activity)

    Repo.insert!(%Timing{
      original_source_id: row.source.id,
      activity_source_id: row.source.id,
      namespace: namespace,
      source_date: result.source_date,
      precision: Atom.to_string(result.precision),
      period: result.period,
      starts_at: result.starts_at,
      ends_at: result.ends_at,
      time_zone: result.time_zone,
      source_snapshot: snapshot,
      input_digest: input_digest(snapshot),
      rule_version: result.rule_version,
      policy: result.policy,
      evidence_origin: "legacy_code"
    })
  end

  defp source_snapshot(%Activity{} = activity) do
    %{
      "date" => Date.to_iso8601(activity.date),
      "raw_task" => activity.raw_task,
      "period" => activity.period
    }
  end

  defp input_digest(snapshot) do
    {snapshot, @rule_version}
    |> :erlang.term_to_binary([:deterministic])
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp increment(counts, key), do: Map.update!(counts, key, &(&1 + 1))
end
