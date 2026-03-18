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
  Gets a single schedule resident by id. Preloads rotations ordered by start_date and
  the schedule association. The virtual name field is populated from the associated Resident.
  Raises if not found. Exempt from doctest — hits the database.
  """
  def get_resident!(id) do
    rotations_query = from(r in ResidencySchedule.Rotations.Rotation, order_by: r.start_date)

    from(sr in ScheduleResident,
      join: r in assoc(sr, :resident),
      where: sr.id == ^id,
      preload: [rotations: ^rotations_query, schedule: []],
      select: %{sr | name: r.name}
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
  Returns all schedule appearances for a resident with the given canonical name,
  ordered by academic year ascending. Each result includes the schedule preloaded.
  Exempt from doctest — hits the database.
  """
  def list_by_canonical_name(canonical_name) do
    from(sr in ScheduleResident,
      join: r in assoc(sr, :resident),
      join: s in assoc(sr, :schedule),
      where: r.name == ^canonical_name,
      order_by: [asc: s.academic_year],
      preload: [:schedule],
      select: %{sr | name: r.name}
    )
    |> Repo.all()
  end

  @doc """
  Finds the most recent schedule resident whose canonical name matches the given password
  (case-insensitive). Returns `nil` if no match is found.
  Exempt from doctest — hits the database.
  """
  def find_by_password(password) do
    normalized = String.downcase(String.trim(password))

    from(sr in ScheduleResident,
      join: r in assoc(sr, :resident),
      join: s in assoc(sr, :schedule),
      where: fragment("lower(trim(?))", r.name) == ^normalized,
      order_by: [desc: s.academic_year],
      limit: 1,
      select: %{sr | name: r.name}
    )
    |> Repo.one()
  end

  @doc """
  Finds or creates a Resident (person) by name, then inserts a ScheduleResident
  for the given schedule. Automatically assigns a unique calendar_token.
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
             schedule_number: Map.get(attrs, :schedule_number),
             calendar_token: Ecto.UUID.generate()
           })
           |> Repo.insert() do
        {:ok, sr} -> {:ok, %{sr | name: person.name}}
        error -> error
      end
    end
  end

  @doc """
  Gets a schedule resident by their unique calendar token. Preloads rotations ordered by start_date.
  The virtual name field is populated from the associated Resident. Raises if not found.
  Exempt from doctest — hits the database.
  """
  def get_resident_by_token!(token) do
    rotations_query = from(r in ResidencySchedule.Rotations.Rotation, order_by: r.start_date)

    from(sr in ScheduleResident,
      join: r in assoc(sr, :resident),
      where: sr.calendar_token == ^token,
      preload: [rotations: ^rotations_query],
      select: %{sr | name: r.name}
    )
    |> Repo.one!()
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

  defp find_or_create_person(nil) do
    %Resident{}
    |> Resident.changeset(%{name: nil})
    |> Repo.insert()
  end

  defp find_or_create_person(name) do
    case Repo.get_by(Resident, name: name) do
      nil ->
        %Resident{}
        |> Resident.changeset(%{name: name})
        |> Repo.insert()

      person ->
        {:ok, person}
    end
  end
end
