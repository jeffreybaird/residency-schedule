defmodule ResidencySchedule.Importer.Csv do
  @moduledoc """
  Minimal CSV codec for schedule files.

  Parses rows into field lists and encodes them back, double-quoting any field
  that contains a comma, quote, or newline. Tolerates `\\r\\n` line endings and
  drops blank lines.
  """

  @doc """
  Parses a CSV binary into a list of row field-lists.

      iex> ResidencySchedule.Importer.Csv.parse("a,b\\r\\n\\"c,d\\",e\\n")
      [["a", "b"], ["c,d", "e"]]
  """
  def parse(binary) do
    binary
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing(&1, "\r"))
    |> Enum.reject(&(&1 == ""))
    |> Enum.map(&parse_line/1)
  end

  @doc """
  Encodes a list of row field-lists into a CSV binary.

      iex> ResidencySchedule.Importer.Csv.encode([["a", "b"], ["c,d", "e"]])
      "a,b\\n\\"c,d\\",e\\n"
  """
  def encode(rows) do
    rows
    |> Enum.map_join("\n", &encode_row/1)
    |> Kernel.<>("\n")
  end

  defp parse_line(line) do
    {fields, current, _quoted?} =
      line
      |> String.codepoints()
      |> Enum.reduce({[], "", false}, &parse_char/2)

    Enum.reverse([current | fields])
  end

  defp parse_char("\"", {fields, "", false}), do: {fields, "", true}
  defp parse_char("\"", {fields, current, true}), do: {fields, current, false}
  defp parse_char(",", {fields, current, false}), do: {[current | fields], "", false}
  defp parse_char(char, {fields, current, quoted?}), do: {fields, current <> char, quoted?}

  defp encode_row(cells), do: Enum.map_join(cells, ",", &encode_cell/1)

  defp encode_cell(cell) do
    if String.contains?(cell, [",", "\"", "\n"]) do
      "\"" <> String.replace(cell, "\"", "\"\"") <> "\""
    else
      cell
    end
  end
end
