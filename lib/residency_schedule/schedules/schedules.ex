defmodule ResidencySchedule.Schedules do
  import Ecto.Query
  alias ResidencySchedule.Repo
  alias ResidencySchedule.Schedules.Schedule
  alias ResidencySchedule.Residents

  @doc """
  Returns all schedules ordered by academic_year ascending (oldest first).
  """
  def list_schedules do
    Schedule
    |> order_by(asc: :academic_year)
    |> Repo.all()
  end

  @doc """
  Gets a single schedule by id. Raises if not found.
  """
  def get_schedule!(id), do: Repo.get!(Schedule, id)

  @doc """
  Gets a schedule by academic year start year. Raises if not found.
  """
  def get_by_year!(year) do
    Repo.get_by!(Schedule, academic_year: year)
  end

  @doc """
  Gets a schedule by academic year start year. Returns nil if not found.

  Exempt from doctest — hits the database.
  """
  def get_by_year(year) do
    Repo.get_by(Schedule, academic_year: year)
  end

  @doc """
  Derives the academic year label from the start year integer.

      iex> ResidencySchedule.Schedules.academic_year_label(2026)
      "2026–2027"

      iex> ResidencySchedule.Schedules.academic_year_label(2023)
      "2023–2024"
  """
  def academic_year_label(start_year) do
    "#{start_year}–#{start_year + 1}"
  end

  @doc """
  Upserts a schedule record for the given academic year.
  If a record with the same academic_year exists, updates its label and updated_at.
  Returns `{:ok, schedule}` or `{:error, changeset}`.
  """
  def upsert_schedule(academic_year, label) do
    %Schedule{}
    |> Schedule.changeset(%{academic_year: academic_year, label: label})
    |> Repo.insert(
      on_conflict: [set: [label: label, updated_at: DateTime.utc_now(:second)]],
      conflict_target: :academic_year,
      returning: true
    )
  end

  @doc """
  Deletes a schedule and all associated schedule_residents and rotations (via DB cascade).
  Resident (person) records that no longer appear in any schedule are also removed.
  Returns `{:ok, schedule}` or `{:error, :not_found}`.
  Exempt from doctest — hits the database.
  """
  def delete_schedule(id) do
    case Repo.get(Schedule, id) do
      nil ->
        {:error, :not_found}

      schedule ->
        result = Repo.delete(schedule)
        Residents.delete_orphaned_residents()
        result
    end
  end

  @doc """
  Returns the schedule whose rotations span the given date, or nil when no
  imported schedule covers it.

  Exempt from doctest — hits the database. See `SchedulesTest`.
  """
  def get_schedule_for_date(%Date{} = date) do
    from(s in Schedule,
      join: sr in assoc(s, :schedule_residents),
      join: r in assoc(sr, :rotations),
      where: r.start_date <= ^date and r.end_date >= ^date,
      order_by: [desc: s.academic_year],
      limit: 1,
      select: s
    )
    |> Repo.one()
  end

  @doc """
  Every schedule with the first and last dates its rotations cover, oldest
  first. A schedule with no rotations yet has nil dates.

  Exempt from doctest — hits the database. See `SchedulesTest`.
  """
  def list_schedule_ranges do
    from(s in Schedule,
      left_join: sr in assoc(s, :schedule_residents),
      left_join: r in assoc(sr, :rotations),
      group_by: [s.id, s.academic_year, s.label],
      order_by: [asc: s.academic_year],
      select: %{
        id: s.id,
        academic_year: s.academic_year,
        label: s.label,
        start_date: min(r.start_date),
        end_date: max(r.end_date)
      }
    )
    |> Repo.all()
  end

  @doc """
  Returns the most recent schedule by academic year, or nil if none exist.
  """
  def latest_schedule do
    Schedule
    |> order_by(desc: :academic_year)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Returns schedules that contain at least one future slot — i.e. the academic year
  has not yet ended (academic year ends June 30 of year+1).
  These are the schedules available for editing on the edit page.

      iex> ResidencySchedule.Schedules.list_editable_schedules() |> is_list()
      true
  """
  def list_editable_schedules do
    today = Date.utc_today()

    list_schedules()
    |> Enum.filter(fn s -> Date.compare(Date.new!(s.academic_year + 1, 6, 30), today) != :lt end)
  end
end
