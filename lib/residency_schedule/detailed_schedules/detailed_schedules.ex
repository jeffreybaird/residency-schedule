defmodule ResidencySchedule.DetailedSchedules do
  @moduledoc "Persists confirmed QGenda detail without replacing rotations or absent assignments."
  import Ecto.Query
  alias ResidencySchedule.Accounts.User

  alias ResidencySchedule.DetailedSchedules.{
    Activity,
    ActivitySearch,
    ActivitySource,
    ImportBatch
  }

  alias ResidencySchedule.Repo
  alias ResidencySchedule.ResidentDisplayNames
  alias ResidencySchedule.Residents.{Resident, ScheduleResident}
  alias ResidencySchedule.Schedules.Schedule

  @doc """
  Saves a server-held preview after rechecking administrator access and roster identity.
  Imports are additive and idempotent. Exempt from doctest — database operation.
  """
  def commit(%{schedule_id: schedule_id, academic_year: year} = preview, %User{id: user_id}) do
    Repo.transaction(fn ->
      require_admin(user_id)
      schedule = Repo.one(from s in Schedule, where: s.id == ^schedule_id, lock: "FOR UPDATE")

      if is_nil(schedule) or schedule.academic_year != year,
        do: Repo.rollback("The selected schedule changed. Preview again.")

      roster = locked_roster(schedule_id)
      validate_preview(preview, roster, year)
      persist_preview(preview, user_id)
    end)
  rescue
    _ -> {:error, "Detailed assignments could not be saved. Refresh the preview and try again."}
  end

  def commit(_, _), do: {:error, "An administrator must prepare a valid preview before saving."}

  @doc """
  Searches dated activities by academic year, literal task, note or resident name text.
  Optional date and stable person filters narrow results; pages contain at most 100 activities.
  Returns neutral display fields without import provenance. Exempt from doctest — database query.
  """
  def search(params) do
    with {:ok, result} <- ActivitySearch.prepare(params) do
      entries = result.query |> load_activities() |> Enum.map(&search_entry/1)
      {:ok, result |> Map.delete(:query) |> Map.put(:entries, entries)}
    end
  end

  @doc """
  Lists up to 20 distinct stored task labels matching the current year, date,
  resident and literal query filters. Exempt from doctest — database query.
  """
  def activity_suggestions(params), do: ActivitySearch.suggestions(params)

  defp search_entry(activity) do
    Map.take(activity, [
      :id,
      :schedule_resident_id,
      :resident_id,
      :position_code,
      :date,
      :raw_task,
      :period,
      :site,
      :display_name,
      :notes
    ])
  end

  @doc "Lists detail for one schedule and date. Exempt from doctest — database query."
  def list_for_date(schedule_id, date) do
    activity_query()
    |> where([a, sr], sr.schedule_id == ^schedule_id and a.date == ^date)
    |> load_activities()
  end

  @doc "Lists detail for one schedule resident and date. Exempt from doctest — database query."
  def list_for_resident(schedule_resident_id, date) do
    activity_query()
    |> where([a], a.schedule_resident_id == ^schedule_resident_id and a.date == ^date)
    |> load_activities()
  end

  @doc """
  Lists a resident's assignments within an inclusive range of at most 370 days.
  Invalid or reversed ranges return no rows. Exempt from doctest — database query.
  """
  def list_for_resident_range(resident_id, %Date{} = first, %Date{} = last)
      when is_integer(resident_id) do
    if Date.diff(last, first) in 0..369 do
      activity_query()
      |> where(
        [a],
        a.schedule_resident_id == ^resident_id and a.date >= ^first and a.date <= ^last
      )
      |> load_activities()
    else
      []
    end
  end

  def list_for_resident_range(_, _, _), do: []

  @doc "Lists detail across schedules for a visible date range. Exempt from doctest — database query."
  def list_in_range(first, last) do
    activity_query() |> where([a], a.date >= ^first and a.date <= ^last) |> load_activities()
  end

  @doc "Reports whether replacing a schedule would discard imported detail. Exempt from doctest — database query."
  def has_detail?(schedule_id),
    do: Repo.exists?(from batch in ImportBatch, where: batch.schedule_id == ^schedule_id)

  defp require_admin(user_id) do
    case Repo.one(from u in User, where: u.id == ^user_id, lock: "FOR SHARE") do
      %User{role: :admin} -> :ok
      _ -> Repo.rollback("Administrator access is required to save detailed assignments.")
    end
  end

  defp locked_roster(schedule_id) do
    Repo.all(
      from sr in ScheduleResident,
        join: r in Resident,
        on: r.id == sr.resident_id,
        where: sr.schedule_id == ^schedule_id,
        lock: "FOR SHARE",
        select: %{
          id: sr.id,
          resident_id: sr.resident_id,
          position_code: sr.position_code,
          name: r.name
        }
    )
  end

  defp validate_preview(preview, roster, year) do
    expected = Enum.sort_by(preview.roster_snapshot, & &1.id)

    if Enum.sort_by(roster, & &1.id) != expected,
      do: Repo.rollback("Resident names or positions changed. Preview the workbook again.")

    valid_dates = Date.range(Date.new!(year, 6, 1), Date.new!(year + 1, 6, 30))
    {first, last} = preview.header_range

    if first not in valid_dates or last not in valid_dates,
      do: Repo.rollback("Workbook dates do not belong to the selected academic year.")

    by_id = Map.new(roster, &{&1.id, &1})
    Enum.each(preview.assignments, &validate_assignment(&1, by_id, valid_dates))
  end

  defp validate_assignment(assignment, roster, valid_dates) do
    if assignment.date not in valid_dates,
      do: Repo.rollback("Assignment dates do not belong to the selected academic year.")

    if assignment.resident_id do
      case Map.get(roster, assignment.schedule_resident_id) do
        %{resident_id: person, name: name}
        when person == assignment.resident_id and name == assignment.previous_name ->
          :ok

        _ ->
          Repo.rollback("A resident identity changed. Preview the workbook again.")
      end
    end
  end

  defp persist_preview(preview, user_id) do
    now = DateTime.utc_now(:second)
    matched = Enum.reject(preview.assignments, &is_nil(&1.resident_id))

    if matched == [],
      do:
        Repo.rollback(
          "No resident assignments are matched. Review the names or upload a crosswalk before saving."
        )

    batch = persist_batch(preview, user_id, now)
    validate_source_identity(matched, batch.id)
    unique = Enum.uniq_by(matched, &activity_key/1)
    rows = Enum.map(unique, &activity_row(&1, now))
    {inserted, _} = insert_rows(Activity, rows, [:schedule_resident_id, :date, :raw_task])
    ids = activity_ids(preview.schedule_id)
    notes = Enum.group_by(preview.notes, & &1.assignment_key)
    sources = Enum.map(matched, &source_row(&1, notes, batch.id, ids, now))
    insert_rows(ActivitySource, sources, [:batch_id, :source_sheet, :source_cell])

    %{
      batch_id: batch.id,
      inserted: inserted,
      existing: length(unique) - inserted,
      skipped: length(preview.assignments) - length(matched)
    }
  end

  defp validate_source_identity(matched, batch_id) do
    occurrences = Enum.map(matched, &{&1.source_sheet, &1.source_cell})

    if length(Enum.uniq(occurrences)) != length(occurrences),
      do:
        Repo.rollback(
          "The workbook contains duplicate source coordinates. Review the source sheets before saving."
        )

    existing =
      from(s in ActivitySource,
        join: a in assoc(s, :activity),
        where: s.batch_id == ^batch_id,
        select: {s.source_sheet, s.source_cell, a.schedule_resident_id, a.date, a.raw_task}
      )
      |> Repo.all()
      |> Map.new(fn {sheet, cell, resident, date, task} ->
        {{sheet, cell}, {resident, date, task}}
      end)

    Enum.each(matched, fn row ->
      previous = Map.get(existing, {row.source_sheet, row.source_cell})

      if previous && previous != activity_key(row),
        do:
          Repo.rollback(
            "This source assignment was already saved for a different resident or task. Corrections require review."
          )
    end)
  end

  defp insert_rows(schema, rows, target) do
    rows
    |> Enum.chunk_every(1000)
    |> Enum.reduce({0, nil}, fn chunk, {count, nil} ->
      {inserted, _} =
        Repo.insert_all(schema, chunk, on_conflict: :nothing, conflict_target: target)

      {count + inserted, nil}
    end)
  end

  defp persist_batch(preview, user_id, now) do
    {first, last} = preview.header_range

    row = %{
      schedule_id: preview.schedule_id,
      created_by_id: user_id,
      fingerprint: preview.fingerprint,
      header_start: first,
      header_end: last,
      inserted_at: now,
      updated_at: now
    }

    Repo.insert_all(ImportBatch, [row],
      on_conflict: :nothing,
      conflict_target: [:schedule_id, :fingerprint]
    )

    Repo.get_by!(ImportBatch, schedule_id: preview.schedule_id, fingerprint: preview.fingerprint)
  end

  defp activity_row(assignment, now) do
    %{
      schedule_resident_id: assignment.schedule_resident_id,
      date: assignment.date,
      raw_task: assignment.raw_task,
      period: explicit_period(assignment.raw_task),
      site: explicit_site(assignment.raw_task),
      inserted_at: now,
      updated_at: now
    }
  end

  defp explicit_period(task) do
    case Regex.run(~r/\b(AM|PM|Day|Night)\b/, task) do
      [_, period] -> period
      _ -> nil
    end
  end

  defp explicit_site(task) do
    case Regex.run(~r/^(GOG|COB|Lattimore|SMH|HH|NMH)\b/, task) do
      [_, site] -> site
      _ -> nil
    end
  end

  defp activity_ids(schedule_id) do
    from(a in Activity,
      join: sr in ScheduleResident,
      on: sr.id == a.schedule_resident_id,
      where: sr.schedule_id == ^schedule_id,
      select: a
    )
    |> Repo.all()
    |> Map.new(&{activity_key(&1), &1.id})
  end

  defp activity_key(row), do: {row.schedule_resident_id, row.date, row.raw_task}

  defp source_row(assignment, notes, batch_id, ids, now) do
    key = {assignment.date, assignment.raw_staff, assignment.raw_task}

    linked =
      notes
      |> Map.get(key, [])
      |> Enum.map(&%{text: &1.body, source_sheet: &1.source_sheet, source_cell: &1.source_cell})

    %{
      activity_id: Map.fetch!(ids, activity_key(assignment)),
      batch_id: batch_id,
      source_sheet: assignment.source_sheet,
      source_cell: assignment.source_cell,
      raw_staff: assignment.raw_staff,
      display_name: assignment.display_name,
      previous_name: assignment.previous_name,
      notes: linked,
      inserted_at: now,
      updated_at: now
    }
  end

  defp activity_query do
    from a in Activity,
      join: sr in assoc(a, :schedule_resident),
      order_by: [asc: a.date, asc: sr.position_code, asc: a.id],
      preload: [:sources, :schedule_resident]
  end

  defp load_activities(query) do
    rows = query |> Repo.all() |> Enum.map(&present_activity/1)
    names = rows |> Enum.map(& &1.resident_id) |> ResidentDisplayNames.names_for_people()

    Enum.map(
      rows,
      &%{&1 | display_name: Map.get(names, &1.resident_id, &1.display_name)}
    )
  end

  defp present_activity(activity) do
    sources = activity.sources |> Enum.sort_by(& &1.id) |> Enum.map(&present_source/1)
    latest = List.last(sources)

    activity
    |> Map.from_struct()
    |> Map.drop([:__meta__, :schedule_resident])
    |> Map.merge(%{
      resident_id: activity.schedule_resident.resident_id,
      position_code: activity.schedule_resident.position_code,
      raw_staff: latest.raw_staff,
      display_name: latest.display_name,
      previous_name: latest.previous_name,
      sources: sources,
      notes: sources |> Enum.flat_map(& &1.notes) |> Enum.map(& &1.text) |> Enum.uniq()
    })
  end

  defp present_source(source) do
    notes =
      Enum.map(
        source.notes,
        &%{text: &1["text"], source_sheet: &1["source_sheet"], source_cell: &1["source_cell"]}
      )

    source
    |> Map.from_struct()
    |> Map.drop([:__meta__, :activity, :batch])
    |> Map.put(:notes, notes)
  end
end
