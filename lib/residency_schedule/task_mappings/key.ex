defmodule ResidencySchedule.TaskMappings.Key do
  @moduledoc false
  alias ResidencySchedule.IdentityMappings.Key, as: IdentityKey
  alias ResidencySchedule.Importer.CsvParser

  @doc """
  Preserves exact QGenda labels and the existing CSV abbreviation policy.

      iex> ResidencySchedule.TaskMappings.Key.normalize(:csv, " GYN - till 8p ")
      {:ok, %{lookup_key: "gyn", normalization_version: "csv_abbreviation_v1"}}
  """
  def normalize(namespace, label) when namespace in [:csv, :qgenda] do
    if IdentityKey.valid_literal?(label) do
      lookup = if namespace == :csv, do: CsvParser.normalize_task_label(label), else: label

      if IdentityKey.valid_literal?(lookup),
        do: {:ok, %{lookup_key: lookup, normalization_version: version(namespace)}},
        else: {:error, :invalid_source_key}
    else
      {:error, :invalid_source_key}
    end
  end

  def normalize(_namespace, _label), do: {:error, :invalid_namespace}

  defp version(:csv), do: "csv_abbreviation_v1"
  defp version(:qgenda), do: "qgenda_exact_v1"
end
