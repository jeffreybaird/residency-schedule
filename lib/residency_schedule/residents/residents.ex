defmodule ResidencySchedule.Residents do
  import Ecto.Query
  alias ResidencySchedule.Repo
  alias ResidencySchedule.Residents.Resident
  alias ResidencySchedule.Schedules.Schedule

  @doc """
  Returns all residents ordered by residency_year ASC, schedule_number ASC.
  """
  def list_residents do
    Resident
    |> order_by(asc: :residency_year, asc: :schedule_number)
    |> Repo.all()
  end

  @doc """
  Returns residents for a given schedule, ordered by residency_year, schedule_number.
  """
  def list_residents_for_schedule(schedule_id) do
    Resident
    |> where(schedule_id: ^schedule_id)
    |> order_by(asc: :residency_year, asc: :schedule_number)
    |> Repo.all()
  end

  @doc """
  Returns residents for a given schedule filtered by residency year.
  """
  def list_residents_by_year(schedule_id, residency_year) do
    Resident
    |> where(schedule_id: ^schedule_id, residency_year: ^residency_year)
    |> order_by(asc: :schedule_number)
    |> Repo.all()
  end

  @doc """
  Gets a single resident by id. Preloads rotations ordered by start_date.
  Raises if not found.
  """
  def get_resident!(id) do
    Resident
    |> Repo.get!(id)
    |> Repo.preload(rotations: from(r in ResidencySchedule.Rotations.Rotation, order_by: r.start_date))
  end

  @doc """
  Gets a resident by position code. Raises if not found.
  """
  def get_resident_by_position!(position_code) do
    Repo.get_by!(Resident, position_code: position_code)
  end

  @doc """
  Returns all schedule appearances for a resident with the given canonical name,
  ordered by academic year ascending. Each result includes the schedule preloaded.
  """
  def list_by_canonical_name(canonical_name) do
    Resident
    |> join(:inner, [r], s in Schedule, on: r.schedule_id == s.id)
    |> where([r, _s], r.name == ^canonical_name)
    |> order_by([_r, s], asc: s.academic_year)
    |> preload(:schedule)
    |> Repo.all()
  end

  @doc """
  Finds the most recent resident whose canonical name matches the given password
  (case-insensitive). Returns `nil` if no match is found.
  """
  def find_by_password(password) do
    normalized = String.downcase(String.trim(password))

    Resident
    |> join(:inner, [r], s in Schedule, on: r.schedule_id == s.id)
    |> where([r, _s], fragment("lower(trim(?))", r.name) == ^normalized)
    |> order_by([_r, s], desc: s.academic_year)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Inserts a resident for the given schedule.
  Returns `{:ok, resident}` or `{:error, changeset}`.
  """
  def insert_resident(schedule_id, attrs) do
    %Resident{}
    |> Resident.changeset(Map.put(attrs, :schedule_id, schedule_id))
    |> Repo.insert()
  end
end
