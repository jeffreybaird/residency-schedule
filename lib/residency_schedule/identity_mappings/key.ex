defmodule ResidencySchedule.IdentityMappings.Key do
  @moduledoc false

  @doc """
  Normalizes bounded literal keys using a closed, namespace-specific policy.

      iex> ResidencySchedule.IdentityMappings.Key.normalize(:csv, "  Iris  Reed ")
      {:ok, %{lookup_key: "iris reed", normalization_version: "csv_alias_v1"}}
  """
  def normalize(namespace, key) when namespace in [:csv, :qgenda] do
    if valid_literal?(key) do
      lookup = key |> display(namespace) |> fold()

      if valid_literal?(lookup),
        do: {:ok, %{lookup_key: lookup, normalization_version: version(namespace)}},
        else: {:error, :invalid_source_key}
    else
      {:error, :invalid_source_key}
    end
  end

  def normalize(_namespace, _key), do: {:error, :invalid_namespace}

  @doc """
  Tests whether a literal fits the text and index bounds.

      iex> ResidencySchedule.IdentityMappings.Key.valid_literal?("Iris")
      true
  """
  def valid_literal?(key) when is_binary(key) and byte_size(key) in 1..512,
    do: String.valid?(key) and not String.contains?(key, <<0>>) and String.trim(key) != ""

  def valid_literal?(_key), do: false

  @doc """
  Folds case and repeated whitespace without interpreting punctuation.

      iex> ResidencySchedule.IdentityMappings.Key.fold(" Iris  Reed ")
      "iris reed"
  """
  def fold(value),
    do: value |> String.trim() |> String.downcase() |> String.replace(~r/\s+/u, " ")

  defp display(key, :csv), do: key

  defp display(key, :qgenda) do
    case String.split(key, ",", parts: 2) do
      [last, first] -> String.trim(first) <> " " <> String.trim(last)
      [name] -> name
    end
  end

  defp version(:csv), do: "csv_alias_v1"
  defp version(:qgenda), do: "qgenda_full_name_v1"
end
