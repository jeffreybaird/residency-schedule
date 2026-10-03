defmodule ResidencySchedule.ResidentDisplayNames do
  @moduledoc "Resolves presentation names by stable person identity without changing roster records."
  import Ecto.Query
  alias ResidencySchedule.DetailedSchedules.ActivitySource
  alias ResidencySchedule.Repo

  @resident_fields [:resident, :covered_by, :original_resident]

  @doc """
  Returns imported names for the requested people in one query. The latest
  academic year wins, followed by the latest source occurrence in that year.
  Exempt from doctest — database query.
  """
  def names_for_people([]), do: %{}

  def names_for_people(person_ids) do
    from(source in ActivitySource,
      join: activity in assoc(source, :activity),
      join: resident in assoc(activity, :schedule_resident),
      join: schedule in assoc(resident, :schedule),
      join: person in assoc(resident, :resident),
      where: resident.resident_id in ^Enum.uniq(person_ids) and source.display_name != "",
      distinct: resident.resident_id,
      order_by: [asc: resident.resident_id, desc: schedule.academic_year, desc: source.id],
      select: {resident.resident_id, source.display_name, person.name}
    )
    |> Repo.all()
    |> Map.new(fn {id, name, fallback} -> {id, choose_display_name(name, fallback)} end)
  end

  @doc """
  Applies preferred names to virtual schedule-resident fields in one batch.
  Stored names and resident identity links are unchanged.
  Exempt from doctest — database query.
  """
  def apply_to_schedule_residents(residents) do
    names = residents |> Enum.map(& &1.resident_id) |> names_for_people()
    Enum.map(residents, &put_name(&1, names))
  end

  @doc """
  Applies presentation names to residents and covering residents in view rows.
  Exempt from doctest — database query.
  """
  def apply_to_entries(entries) do
    names =
      entries
      |> Enum.flat_map(&Map.take(&1, @resident_fields))
      |> Enum.map(&elem(&1, 1))
      |> Enum.reject(&is_nil/1)
      |> Enum.map(& &1.resident_id)
      |> names_for_people()

    Enum.map(entries, fn entry ->
      Enum.reduce(@resident_fields, entry, &put_entry_name(&1, &2, names))
    end)
  end

  @doc """
  Chooses an imported name or a normalized existing name for display.

      iex> ResidencySchedule.ResidentDisplayNames.name_for(7, "Reed, Iris", %{})
      "Iris Reed"
      iex> ResidencySchedule.ResidentDisplayNames.name_for(7, "Juniper", %{7 => "Juniper Vale"})
      "Juniper Vale"
  """
  def name_for(person_id, fallback, names),
    do: choose_display_name(Map.get(names, person_id, fallback), fallback)

  defp choose_display_name(imported, fallback) do
    preferred = normalize_name(imported)
    existing = normalize_name(fallback)
    if String.downcase(preferred) == String.downcase(existing), do: existing, else: preferred
  end

  defp put_name(resident, names),
    do: %{resident | name: name_for(resident.resident_id, resident.name, names)}

  defp put_entry_name(field, entry, names) do
    case Map.get(entry, field) do
      nil -> entry
      resident -> Map.put(entry, field, put_name(resident, names))
    end
  end

  defp normalize_name(name) do
    case String.split(name, ",", parts: 2) do
      [last, first] -> String.trim(first) <> " " <> String.trim(last)
      [single] -> String.trim(single)
    end
  end
end
