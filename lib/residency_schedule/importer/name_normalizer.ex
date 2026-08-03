defmodule ResidencySchedule.Importer.NameNormalizer do
  @moduledoc """
  Maps raw resident names to canonical first-name forms using a roster file.

  Names are keyed by {academic_year_start, position_code} because the same
  position code refers to a different person across years, and the same person
  may appear with different spellings or full names in different years.

  The roster is a CSV read from the path configured under
  `config :residency_schedule, :roster_path` (default `data/roster.csv`), with
  columns `academic_year,position_code,canonical_name,aliases` where `aliases`
  is a pipe-separated list of lowercase alternate spellings. The file is parsed
  once per path and cached in `:persistent_term`. When the file is missing or
  unreadable the roster is empty and `normalize/3` falls back to the trimmed
  raw name.
  """

  alias ResidencySchedule.Importer.Csv

  @doc """
  Returns the canonical name for a resident given their academic year start and
  position code. Falls back to the trimmed raw name if no mapping is found.

  Demo deployments keep the raw name from the CSV. The demo fixture covers the
  current academic year so it renders on the calendar, which is inside the range
  the roster covers — without the bypass, its invented names would be rewritten
  to the rostered residents' names.

      iex> ResidencySchedule.Importer.NameNormalizer.normalize(2023, "R1-1", "Quinn Halden")
      "Quinn"

      iex> ResidencySchedule.Importer.NameNormalizer.normalize(2025, "R4-4", "Katy ")
      "Katy G"

      iex> ResidencySchedule.Importer.NameNormalizer.normalize(2099, "R1-1", "Unknown Name")
      "Unknown Name"
  """
  def normalize(academic_year, position_code, raw_name) do
    if ResidencySchedule.demo_mode?() do
      String.trim(raw_name)
    else
      Map.get(roster().canonical, {academic_year, position_code}, String.trim(raw_name))
    end
  end

  @doc """
  Returns all schedule numbers for a canonical name.

      iex> ResidencySchedule.Importer.NameNormalizer.get_canonical_schedule_numbers("Nora K")
      [{2023, "R2-3"}, {2024, "R3-6"}, {2025, "R4-8"}]
  """
  def get_canonical_schedule_numbers(name) do
    Map.get(roster().by_name, name, [])
  end

  @doc """
  Returns all distinct canonical names known to the normalizer.

      iex> ResidencySchedule.Importer.NameNormalizer.all_canonical_names() |> Enum.member?("Nora K")
      true
  """
  def all_canonical_names do
    roster().by_name
    |> Map.keys()
  end

  @doc """
  Returns the alias map: lowercase alternate spelling to lowercase canonical
  name, for matching roster rows whose raw name differs from the canonical
  form and shares no first token with it.

      iex> ResidencySchedule.Importer.NameNormalizer.aliases()["rose"]
      "rosie"
  """
  def aliases do
    roster().aliases
  end

  # --- Roster loading ---

  defp roster do
    path = Application.get_env(:residency_schedule, :roster_path, "data/roster.csv")

    case :persistent_term.get({__MODULE__, path}, nil) do
      nil ->
        loaded = load_roster(path)
        :persistent_term.put({__MODULE__, path}, loaded)
        loaded

      loaded ->
        loaded
    end
  end

  defp load_roster(path) do
    case File.read(path) do
      {:ok, binary} -> parse_roster(binary)
      {:error, _reason} -> empty_roster()
    end
  end

  defp parse_roster(binary) do
    binary
    |> Csv.parse()
    |> Enum.drop(1)
    |> Enum.reduce(empty_roster(), &add_roster_row/2)
    |> reverse_by_name_entries()
  end

  defp add_roster_row([year, code, name | rest], acc) do
    key = {String.to_integer(year), code}

    %{
      canonical: Map.put(acc.canonical, key, name),
      by_name: Map.update(acc.by_name, name, [key], &[key | &1]),
      aliases: Map.merge(acc.aliases, row_aliases(rest, name))
    }
  end

  defp add_roster_row(_short_row, acc), do: acc

  defp row_aliases([aliases | _], name) when aliases != "" do
    aliases
    |> String.split("|")
    |> Map.new(&{&1, String.downcase(name)})
  end

  defp row_aliases(_rest, _name), do: %{}

  defp reverse_by_name_entries(acc) do
    %{acc | by_name: Map.new(acc.by_name, fn {name, keys} -> {name, Enum.reverse(keys)} end)}
  end

  defp empty_roster do
    %{canonical: %{}, by_name: %{}, aliases: %{}}
  end
end
