defmodule ResidencySchedule.SourceProvenance do
  @moduledoc "Backfills known source references without inventing missing historical provenance."
  import Ecto.Query

  alias ResidencySchedule.DetailedSchedules.{ActivitySource, ImportBatch}
  alias ResidencySchedule.Repo

  @doc """
  Fills empty QGenda references from their retained worksheet and cell coordinates.

  Reads source IDs in bounded ascending batches. Each update rechecks the empty
  reference and QGenda source kind so concurrent provenance changes are preserved.
  Existing fields and timestamps are untouched. Repeating the call changes no
  populated references. `:batch_size` defaults to 500 and must be in 1..1000.

  Database operation; tested through integration tests instead of doctests.
  """
  def backfill(options \\ []) do
    with {:ok, batch_size} <- batch_size(options) do
      {:ok, %{activity_sources_updated: fill_references(0, batch_size, 0)}}
    end
  rescue
    _ -> {:error, "Source provenance could not be backfilled. The operation may be retried."}
  end

  defp batch_size(options) when is_list(options) do
    if Keyword.keyword?(options) and Enum.all?(Keyword.keys(options), &(&1 == :batch_size)) do
      validate_batch_size(Keyword.get(options, :batch_size, 500))
    else
      {:error, "Choose a provenance batch size from 1 to 1000."}
    end
  end

  defp batch_size(_options), do: {:error, "Choose a provenance batch size from 1 to 1000."}

  defp validate_batch_size(size) when is_integer(size) and size in 1..1000, do: {:ok, size}
  defp validate_batch_size(_size), do: {:error, "Choose a provenance batch size from 1 to 1000."}

  defp fill_references(after_id, batch_size, updated) do
    ids =
      eligible_sources()
      |> where([source], source.id > ^after_id)
      |> order_by([source], asc: source.id)
      |> limit(^batch_size)
      |> select([source], source.id)
      |> Repo.all()

    case ids do
      [] ->
        updated

      _ ->
        count = fill_batch(ids)
        fill_references(List.last(ids), batch_size, updated + count)
    end
  end

  defp eligible_sources do
    from source in ActivitySource,
      join: batch in ImportBatch,
      on: batch.id == source.batch_id,
      where: source.source_reference == ^%{} and batch.source_kind == "qgenda"
  end

  defp fill_batch(ids) do
    query =
      eligible_sources()
      |> where([source], source.id in ^ids)
      |> update([source],
        set: [
          source_reference:
            fragment(
              "jsonb_build_object('sheet', ?, 'cell', ?)",
              source.source_sheet,
              source.source_cell
            )
        ]
      )

    {count, nil} = Repo.update_all(query, [])
    count
  end
end
