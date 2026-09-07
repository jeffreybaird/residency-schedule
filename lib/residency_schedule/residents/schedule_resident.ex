defmodule ResidencySchedule.Residents.ScheduleResident do
  use Ecto.Schema
  import Ecto.Changeset

  schema "schedule_residents" do
    field :position_code, :string
    field :residency_year, :integer
    field :schedule_number, :integer

    # Virtual field populated at query time from the associated Resident.name.
    # All code that previously accessed resident.name continues to work unchanged.
    field :name, :string, virtual: true

    belongs_to :resident, ResidencySchedule.Residents.Resident
    belongs_to :schedule, ResidencySchedule.Schedules.Schedule
    has_many :rotations, ResidencySchedule.Rotations.Rotation, foreign_key: :schedule_resident_id

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating a schedule resident (a person's position in one academic year).

      iex> cs = ResidencySchedule.Residents.ScheduleResident.changeset(
      ...>   %ResidencySchedule.Residents.ScheduleResident{},
      ...>   %{resident_id: 1, schedule_id: 1, position_code: "R1-1", residency_year: 1, schedule_number: 1}
      ...> )
      iex> cs.valid?
      true
  """
  def changeset(sr, attrs) do
    sr
    |> cast(attrs, [
      :resident_id,
      :schedule_id,
      :position_code,
      :residency_year,
      :schedule_number
    ])
    |> validate_required([
      :resident_id,
      :schedule_id,
      :position_code,
      :residency_year,
      :schedule_number
    ])
    |> unique_constraint([:schedule_id, :position_code])
    |> unique_constraint([:schedule_id, :resident_id])
  end

  @doc """
  Returns a base query that joins residents and populates the virtual name field.
  Use this query as a preload argument wherever ScheduleResident associations are loaded
  and callers need the .name virtual field to be set.

      iex> import Ecto.Query
      iex> q = ResidencySchedule.Residents.ScheduleResident.with_name_query()
      iex> match?(%Ecto.Query{}, q)
      true
  """
  def with_name_query do
    import Ecto.Query

    from(sr in __MODULE__,
      join: r in assoc(sr, :resident),
      select: %{sr | name: r.name}
    )
  end
end
