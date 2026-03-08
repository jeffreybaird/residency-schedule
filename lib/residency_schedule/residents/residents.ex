defmodule ResidencySchedule.Residents do
  import Ecto.Query
  alias ResidencySchedule.Repo
  alias ResidencySchedule.Residents.Resident

  @doc """
  Returns all residents ordered by residency_year ASC, schedule_number ASC.

      iex> ResidencySchedule.Residents.list_residents()
      []
  """
  def list_residents do
    Resident
    |> order_by(asc: :residency_year, asc: :schedule_number)
    |> Repo.all()
  end

  @doc """
  Returns residents for a given schedule, ordered by residency_year, schedule_number.

      iex> ResidencySchedule.Residents.list_residents_for_schedule(0)
      []
  """
  def list_residents_for_schedule(schedule_id) do
    Resident
    |> where(schedule_id: ^schedule_id)
    |> order_by(asc: :residency_year, asc: :schedule_number)
    |> Repo.all()
  end

  @doc """
  Returns residents for a given schedule filtered by residency year.

      iex> ResidencySchedule.Residents.list_residents_by_year(0, 4)
      []
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

      iex> ResidencySchedule.Residents.get_resident!(0)
      ** (Ecto.NoResultsError)
  """
  def get_resident!(id) do
    Resident
    |> Repo.get!(id)
    |> Repo.preload(rotations: from(r in ResidencySchedule.Rotations.Rotation, order_by: r.start_date))
  end

  @doc """
  Gets a resident by position code. Raises if not found.

      iex> ResidencySchedule.Residents.get_resident_by_position!("R9-99")
      ** (Ecto.NoResultsError)
  """
  def get_resident_by_position!(position_code) do
    Repo.get_by!(Resident, position_code: position_code)
  end

  @doc """
  Inserts a resident for the given schedule.
  Returns `{:ok, resident}` or `{:error, changeset}`.

      iex> {:error, changeset} = ResidencySchedule.Residents.insert_resident(0, %{position_code: nil, residency_year: nil, schedule_number: nil, name: nil})
      iex> changeset.valid?
      false
  """
  def insert_resident(schedule_id, attrs) do
    %Resident{}
    |> Resident.changeset(Map.put(attrs, :schedule_id, schedule_id))
    |> Repo.insert()
  end
end
