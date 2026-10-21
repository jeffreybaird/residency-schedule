defmodule ResidencySchedule.Importer.Preview do
  @moduledoc "Shared source-adapter entry point for read-only import reconciliation."

  alias ResidencySchedule.Importer.Adapters.{Csv, Json, Qgenda}
  alias ResidencySchedule.Importer.{ImportDocument, QgendaPreview, ScheduleImporter}

  @adapters %{csv: Csv, qgenda: Qgenda, json: Json}

  @doc """
  Prepares source facts through the existing domain reconciliation services.
  New JSON input is preview-only; this function never commits records.
  Database operation; covered by integration tests instead of doctests.
  """
  def prepare(format, binary, options) do
    with {:ok, adapter} <- fetch_adapter(format),
         {:ok, document} <- adapter.parse(binary, options) do
      prepare_document(document, options)
    end
  end

  defp fetch_adapter(format) do
    case Map.fetch(@adapters, format) do
      {:ok, adapter} -> {:ok, adapter}
      :error -> {:error, "Unsupported import format"}
    end
  end

  defp prepare_document(%ImportDocument{kind: :rotations} = document, options),
    do: ScheduleImporter.prepare_document(document, options)

  defp prepare_document(%ImportDocument{kind: :activities} = document, options),
    do: QgendaPreview.prepare_document(document, options)
end
