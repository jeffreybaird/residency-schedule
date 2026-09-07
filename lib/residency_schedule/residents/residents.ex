defmodule ResidencySchedule.Residents do
  import Ecto.Query
  alias ResidencySchedule.Repo
  alias ResidencySchedule.Residents.Resident
  alias ResidencySchedule.Residents.ScheduleResident

  @doc """
  Returns all residents (people) ordered by name.
  """
  def list_residents do
    Resident
    |> order_by(asc: :name)
    |> Repo.all()
  end

  @doc """
  Returns one option per resident (person) who has at least one shift in the
  given academic year, for calendar filtering: their `resident_id`, name, and
  position code. Ordered by residency_year, schedule_number.

  Residents without a shift that academic year (and residents from other years)
  are excluded.

  Exempt from doctest — hits the database. See `ResidentsTest`.
  """
  def list_resident_filter_options_for_year(academic_year) do
    from(sr in ScheduleResident,
      join: r in assoc(sr, :resident),
      join: s in assoc(sr, :schedule),
      join: rot in assoc(sr, :rotations),
      where: s.academic_year == ^academic_year,
      order_by: [asc: sr.residency_year, asc: sr.schedule_number],
      select: %{id: sr.resident_id, name: r.name, position_code: sr.position_code}
    )
    |> Repo.all()
    |> Enum.uniq_by(& &1.id)
  end

  @doc """
  Returns schedule residents for a given schedule, ordered by residency_year, schedule_number.
  The virtual name field is populated from the associated Resident.
  """
  def list_residents_for_schedule(schedule_id) do
    from(sr in ScheduleResident,
      join: r in assoc(sr, :resident),
      where: sr.schedule_id == ^schedule_id,
      order_by: [asc: sr.residency_year, asc: sr.schedule_number],
      select: %{sr | name: r.name}
    )
    |> Repo.all()
  end

  @doc """
  Returns schedule residents for a given schedule filtered by residency year.
  The virtual name field is populated from the associated Resident.
  """
  def list_residents_by_year(schedule_id, residency_year) do
    from(sr in ScheduleResident,
      join: r in assoc(sr, :resident),
      where: sr.schedule_id == ^schedule_id and sr.residency_year == ^residency_year,
      order_by: [asc: sr.schedule_number],
      select: %{sr | name: r.name}
    )
    |> Repo.all()
  end

  @doc """
  Returns all schedule residents across the given schedule ids, with rotations preloaded
  and the virtual name field populated. Ordered by residency_year, schedule_number.
  Exempt from doctest — hits the database.
  """
  def list_residents_across_schedules(schedule_ids) do
    rotations_query = from(r in ResidencySchedule.Rotations.Rotation, order_by: r.start_date)

    from(sr in ScheduleResident,
      join: r in assoc(sr, :resident),
      where: sr.schedule_id in ^schedule_ids,
      order_by: [asc: sr.residency_year, asc: sr.schedule_number],
      preload: [rotations: ^rotations_query],
      select: %{sr | name: r.name}
    )
    |> Repo.all()
  end

  @doc """
  Gets a single schedule resident by id. Preloads rotations ordered by start_date,
  the schedule association, and the resident (person) association. The virtual
  name field is populated from the associated Resident.
  Raises if not found. Exempt from doctest — hits the database.
  """
  def get_resident!(id) do
    rotations_query = from(r in ResidencySchedule.Rotations.Rotation, order_by: r.start_date)

    from(sr in ScheduleResident,
      join: r in assoc(sr, :resident),
      where: sr.id == ^id,
      preload: [rotations: ^rotations_query, schedule: []],
      select: %{sr | name: r.name, resident: r}
    )
    |> Repo.one!()
  end

  @doc """
  Gets a schedule resident by position code. Raises if not found.
  Exempt from doctest — hits the database.
  """
  def get_resident_by_position!(position_code) do
    from(sr in ScheduleResident,
      join: r in assoc(sr, :resident),
      where: sr.position_code == ^position_code,
      select: %{sr | name: r.name}
    )
    |> Repo.one!()
  end

  @doc """
  Returns every schedule appearance of one resident (person), ordered by
  academic year ascending. Each result includes the schedule preloaded and the
  virtual name field populated.
  Exempt from doctest — hits the database. See `ResidentsTest`.
  """
  def list_appearances_for_person(person_id) do
    person_id
    |> appearances_query()
    |> order_by([sr, r, s], asc: s.academic_year)
    |> Repo.all()
  end

  @doc """
  Returns the resident's (person's) most recent schedule appearance, with the
  schedule preloaded and the virtual name field populated, or nil when the
  person appears in no schedule.
  Exempt from doctest — hits the database. See `ResidentsTest`.
  """
  def latest_appearance_for_person(person_id) do
    person_id
    |> appearances_query()
    |> order_by([sr, r, s], desc: s.academic_year)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Returns the ids of every schedule appearance of one resident (person).
  Exempt from doctest — hits the database. See `ResidentsTest`.
  """
  def list_schedule_resident_ids_for_person(person_id) do
    from(sr in ScheduleResident, where: sr.resident_id == ^person_id, select: sr.id)
    |> Repo.all()
  end

  @doc """
  Finds or creates a Resident (person) by name, then inserts a ScheduleResident
  for the given schedule. A newly created person is assigned a unique
  calendar_token; an existing person keeps theirs, so the same name across
  academic years resolves to one record.
  Returns `{:ok, schedule_resident}` or `{:error, changeset}`.
  Exempt from doctest — hits the database.
  """
  def insert_resident(schedule_id, attrs) do
    name = Map.get(attrs, :name)

    with {:ok, person} <- find_or_create_person(name) do
      case %ScheduleResident{}
           |> ScheduleResident.changeset(%{
             resident_id: person.id,
             schedule_id: schedule_id,
             position_code: Map.get(attrs, :position_code),
             residency_year: Map.get(attrs, :residency_year),
             schedule_number: Map.get(attrs, :schedule_number)
           })
           |> Repo.insert() do
        {:ok, sr} -> {:ok, %{sr | name: person.name}}
        error -> error
      end
    end
  end

  @doc """
  Gets a resident (person) by their unique calendar token. Raises if not found.
  Exempt from doctest — hits the database. See `CalendarTokenTest`.
  """
  def get_person_by_token!(token) do
    Repo.get_by!(Resident, calendar_token: token)
  end

  @doc """
  Renames a resident (person) across all schedules by updating the single person record.
  Returns `{count, nil}` where count is 1 on success, 0 if the name was not found.
  Exempt from doctest — hits the database.
  """
  def rename_resident(old_name, new_name) do
    from(r in Resident, where: r.name == ^old_name)
    |> Repo.update_all(set: [name: new_name])
  end

  @doc """
  Deletes all Resident (person) records that no longer appear in any schedule.
  Returns `{count, nil}` where count is the number of deleted rows.
  Exempt from doctest — hits the database.
  """
  def delete_orphaned_residents do
    resident_ids_in_use = from(sr in ScheduleResident, select: sr.resident_id)

    from(r in Resident, where: r.id not in subquery(resident_ids_in_use))
    |> Repo.delete_all()
  end

  defp appearances_query(person_id) do
    from(sr in ScheduleResident,
      join: r in assoc(sr, :resident),
      join: s in assoc(sr, :schedule),
      where: sr.resident_id == ^person_id,
      preload: [schedule: s],
      select: %{sr | name: r.name}
    )
  end

  defp find_or_create_person(nil), do: create_person(nil)

  defp find_or_create_person(name) do
    case Repo.get_by(Resident, name: name) do
      nil -> create_person(name)
      person -> {:ok, person}
    end
  end

  defp create_person(name) do
    %Resident{}
    |> Resident.changeset(%{name: name, calendar_token: Ecto.UUID.generate()})
    |> Repo.insert()
  end
end
