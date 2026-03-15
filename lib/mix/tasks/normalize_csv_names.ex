defmodule Mix.Tasks.NormalizeCsvNames do
  use Mix.Task

  @shortdoc "Normalizes resident names in data/ CSVs to canonical form"

  @moduledoc """
  Reads each schedule CSV in the data/ directory, replaces the name column of
  every resident row with its canonical name from NameNormalizer, and writes
  the file back in place.

  Usage:

      mix normalize_csv_names

  The `name_mapping.csv` file in data/ is skipped automatically.
  """

  alias ResidencySchedule.Importer.NameNormalizer

  @resident_row_pattern ~r/^R([1-4])-(\d+)$/

  def run(_args) do
    data_dir = Path.join(File.cwd!(), "data")

    data_dir
    |> Path.join("*.csv")
    |> Path.wildcard()
    |> Enum.reject(&String.contains?(Path.basename(&1), "name_mapping"))
    |> Enum.each(&normalize_file/1)
  end

  @doc false
  def normalize_file(path) do
    year = academic_year_from_path(path)
    normalized = path |> File.read!() |> normalize_content(year)
    File.write!(path, normalized)
    Mix.shell().info("Normalized #{Path.basename(path)}")
  end

  @doc false
  def normalize_content(content, academic_year) do
    content
    |> String.split("\n")
    |> Enum.map(&normalize_line(&1, academic_year))
    |> Enum.join("\n")
  end

  defp academic_year_from_path(path) do
    path
    |> Path.basename(".csv")
    |> String.split("-")
    |> List.first()
    |> String.to_integer()
  end

  defp normalize_line(line, academic_year) do
    trimmed_line = String.trim_trailing(line, "\r")
    line_suffix = if String.ends_with?(line, "\r"), do: "\r", else: ""

    cols = String.split(trimmed_line, ",")

    case cols do
      [position_code | [_name_raw | rest_cols]] when is_binary(position_code) ->
        if Regex.match?(@resident_row_pattern, position_code) do
          canonical = NameNormalizer.normalize(academic_year, position_code, hd(tl(cols)))
          ([position_code, canonical] ++ rest_cols)
          |> Enum.join(",")
          |> Kernel.<>(line_suffix)
        else
          line
        end

      _ ->
        line
    end
  end
end
