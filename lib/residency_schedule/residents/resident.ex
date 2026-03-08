defmodule ResidencySchedule.Residents.Resident do
  use Ecto.Schema
  import Ecto.Changeset

  schema "residents" do
    field :position_code, :string
    field :residency_year, :integer
    field :schedule_number, :integer
    field :name, :string

    belongs_to :schedule, ResidencySchedule.Schedules.Schedule
    has_many :rotations, ResidencySchedule.Rotations.Rotation

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a resident.

      iex> changeset = ResidencySchedule.Residents.Resident.changeset(%ResidencySchedule.Residents.Resident{}, %{schedule_id: 1, position_code: "R4-1", residency_year: 4, schedule_number: 1, name: "Alexis"})
      iex> changeset.valid?
      true
  """
  def changeset(resident, attrs) do
    resident
    |> cast(attrs, [:schedule_id, :position_code, :residency_year, :schedule_number, :name])
    |> validate_required([:schedule_id, :position_code, :residency_year, :schedule_number, :name])
    |> unique_constraint([:schedule_id, :position_code])
  end
end
