defmodule ResidencySchedule.DetailedSchedules.ActivitySearch do
  @moduledoc false
  import Ecto.Query
  alias ResidencySchedule.DetailedSchedules.{Activity, ActivitySource}
  alias ResidencySchedule.Repo
  alias ResidencySchedule.Residents.{Resident, ScheduleResident}
  alias ResidencySchedule.Schedules

  @doc "Validates activity filters and prepares a paginated query. Exempt from doctest — database query."
  def prepare(params) when is_map(params) do
    with {:ok, filters} <- validate_filters(params) do
      filtered = filters |> scoped_query() |> filter_text(filters.query)
      total = Repo.aggregate(filtered, :count, :id)

      paginated =
        from [a, sr] in filtered,
          order_by: [asc: a.date, asc: sr.position_code, asc: a.id],
          limit: ^filters.page_size,
          offset: ^((filters.page - 1) * filters.page_size),
          preload: [:sources, :schedule_resident]

      {:ok, %{query: paginated, total: total, page: filters.page, page_size: filters.page_size}}
    end
  end

  def prepare(_), do: {:error, "Search filters must be an object."}

  @doc "Lists up to 20 distinct task labels in the validated search scope. Exempt from doctest — database query."
  def suggestions(params) when is_map(params) do
    with {:ok, filters} <- validate_filters(params) do
      labels =
        filters
        |> scoped_query()
        |> where([a], fragment("strpos(lower(?), lower(?)) > 0", a.raw_task, ^filters.query))
        |> select([a], a.raw_task)
        |> distinct(true)
        |> order_by([a], asc: a.raw_task)
        |> limit(20)
        |> Repo.all()

      {:ok, labels}
    end
  end

  def suggestions(_), do: {:error, "Search filters must be an object."}

  defp validate_filters(params) do
    with {:ok, year} <- integer(value(params, :academic_year), nil, 1, 9998),
         {:ok, schedule} <- find_schedule(year),
         {:ok, query} <- search_text(value(params, :query)),
         {:ok, first} <- date(value(params, :start_date), Date.new!(year, 6, 1)),
         {:ok, last} <- date(value(params, :end_date), Date.new!(year + 1, 6, 30)),
         :ok <- validate_dates(first, last, year),
         {:ok, person} <- integer(value(params, :resident_id), nil, 1, 2_147_483_647),
         {:ok, page} <- integer(value(params, :page), 1, 1, 10_000),
         {:ok, size} <- integer(value(params, :page_size), 50, 1, 100) do
      {:ok,
       %{
         schedule_id: schedule.id,
         query: query,
         first: first,
         last: last,
         person: person,
         page: page,
         page_size: size
       }}
    end
  end

  defp scoped_query(filters) do
    from(a in Activity,
      as: :activity,
      join: sr in assoc(a, :schedule_resident),
      as: :schedule_resident,
      where:
        sr.schedule_id == ^filters.schedule_id and a.date >= ^filters.first and
          a.date <= ^filters.last
    )
    |> filter_person(filters.person)
  end

  defp value(params, key), do: Map.get(params, key, Map.get(params, Atom.to_string(key)))

  defp find_schedule(nil), do: {:error, "Choose an academic year."}

  defp find_schedule(year) do
    case Schedules.get_by_year(year) do
      nil -> {:error, "The selected academic year does not exist."}
      schedule -> {:ok, schedule}
    end
  end

  defp integer(value, default, _, _) when value in [nil, ""], do: {:ok, default}

  defp integer(value, _, minimum, maximum)
       when is_integer(value) and value >= minimum and value <= maximum,
       do: {:ok, value}

  defp integer(value, default, minimum, maximum) when is_binary(value) do
    case Integer.parse(value) do
      {number, ""} -> integer(number, default, minimum, maximum)
      _ -> {:error, "Year, resident and page filters must be valid numbers."}
    end
  end

  defp integer(_, _, _, _),
    do: {:error, "Year, resident and page filters are outside the allowed range."}

  defp search_text(nil), do: {:ok, ""}

  defp search_text(text) when is_binary(text) do
    if String.length(text) <= 200,
      do: {:ok, String.trim(text)},
      else: {:error, "Search text must be 200 characters or fewer."}
  end

  defp search_text(_), do: {:error, "Search text must be a string."}

  defp date(value, default) when value in [nil, ""], do: {:ok, default}
  defp date(%Date{} = value, _), do: {:ok, value}

  defp date(value, _) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, "Dates must use YYYY-MM-DD."}
    end
  end

  defp date(_, _), do: {:error, "Dates must use YYYY-MM-DD."}

  defp validate_dates(first, last, year) do
    if Date.compare(first, last) != :gt and Date.compare(first, Date.new!(year, 6, 1)) != :lt and
         Date.compare(last, Date.new!(year + 1, 6, 30)) != :gt do
      :ok
    else
      {:error, "Dates must be in order and within the selected academic year."}
    end
  end

  defp filter_person(query, nil), do: query
  defp filter_person(query, person), do: where(query, [_, sr], sr.resident_id == ^person)
  defp filter_text(query, ""), do: query

  defp filter_text(query, text) do
    names =
      from source in ActivitySource,
        join: activity in assoc(source, :activity),
        join: sr in ScheduleResident,
        on: sr.id == activity.schedule_resident_id,
        where: sr.resident_id == parent_as(:schedule_resident).resident_id,
        where:
          fragment("strpos(lower(?), lower(?)) > 0", source.display_name, ^text) or
            fragment("strpos(lower(?), lower(?)) > 0", source.previous_name, ^text) or
            fragment("strpos(lower(?), lower(?)) > 0", source.raw_staff, ^text),
        select: 1

    people =
      from person in Resident,
        where: person.id == parent_as(:schedule_resident).resident_id,
        where:
          fragment("strpos(lower(?), lower(?)) > 0", person.name, ^text) or
            fragment(
              "strpos(lower(trim(split_part(?, ',', 2)) || ' ' || trim(split_part(?, ',', 1))), lower(?)) > 0",
              person.name,
              person.name,
              ^text
            ),
        select: 1

    notes =
      from source in ActivitySource,
        where: source.activity_id == parent_as(:activity).id,
        where:
          fragment(
            "EXISTS (SELECT 1 FROM unnest(?) AS note WHERE strpos(lower(note->>'text'), lower(?)) > 0)",
            source.notes,
            ^text
          ),
        select: 1

    where(
      query,
      [a],
      fragment("strpos(lower(?), lower(?)) > 0", a.raw_task, ^text) or
        exists(subquery(names)) or exists(subquery(people)) or exists(subquery(notes))
    )
  end
end
