defmodule ResidencySchedule.Assistant.ResidentResolver do
  @moduledoc """
  Turns a name someone typed ("Clare", "nora k", "Katie Z") into exactly one
  schedule resident of a schedule, or explains why it cannot.
  """

  alias ResidencySchedule.Importer.NameNormalizer
  alias ResidencySchedule.Residents

  @doc """
  Resolves a name within one schedule.

  Exempt from doctest — hits the database. See `ResidentResolverTest`.
  """
  def resolve(name, schedule_id) do
    schedule_id
    |> Residents.list_residents_for_schedule()
    |> match(name)
  end

  @doc """
  Picks the schedule resident matching a query from a list. Matching order:
  exact full name, then first name, then prefix of the full name, then roster
  aliases. Every comparison is case-insensitive.

  Returns `{:ok, resident}`, `{:error, {:ambiguous, residents}}` when several
  match at the same level, or `{:error, :not_found}`.

      iex> alias ResidencySchedule.Residents.ScheduleResident
      iex> residents = [
      ...>   %ScheduleResident{id: 1, name: "Nora"},
      ...>   %ScheduleResident{id: 2, name: "Nora Kass"},
      ...>   %ScheduleResident{id: 3, name: "Clare"}
      ...> ]
      iex> {:ok, clare} = ResidencySchedule.Assistant.ResidentResolver.match(residents, "clare")
      iex> clare.id
      3
      iex> {:ok, nora_k} = ResidencySchedule.Assistant.ResidentResolver.match(residents, "Nora K")
      iex> nora_k.id
      2
  """
  def match(residents, name) when is_binary(name) do
    query = normalize(name)

    with :none <- pick(residents, &(normalize(&1.name) == query)),
         :none <- pick(residents, &(first_token(&1.name) == query)),
         :none <- pick(residents, &String.starts_with?(normalize(&1.name), query)),
         :none <- match_alias(residents, query) do
      {:error, :not_found}
    end
  end

  def match(_residents, _name), do: {:error, :not_found}

  @doc """
  Normalizes a name for comparison: lowercase, trimmed, single spaces.

      iex> ResidencySchedule.Assistant.ResidentResolver.normalize("  Katie   Z ")
      "katie z"
  """
  def normalize(name) do
    name
    |> String.downcase()
    |> String.split()
    |> Enum.join(" ")
  end

  defp first_token(name), do: name |> normalize() |> String.split(" ") |> hd()

  defp pick(residents, predicate) do
    case Enum.filter(residents, predicate) do
      [] -> :none
      [one] -> {:ok, one}
      many -> {:error, {:ambiguous, many}}
    end
  end

  defp match_alias(residents, query) do
    case Map.get(NameNormalizer.aliases(), query) do
      nil -> :none
      canonical -> pick(residents, &(normalize(&1.name) == canonical))
    end
  end
end
