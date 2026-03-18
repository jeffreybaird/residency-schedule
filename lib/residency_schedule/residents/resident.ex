defmodule ResidencySchedule.Residents.Resident do
  use Ecto.Schema
  import Ecto.Changeset

  schema "residents" do
    field :name, :string

    has_many :schedule_residents, ResidencySchedule.Residents.ScheduleResident

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a resident (person).

      iex> changeset = ResidencySchedule.Residents.Resident.changeset(%ResidencySchedule.Residents.Resident{}, %{name: "Alexis"})
      iex> changeset.valid?
      true
  """
  def changeset(resident, attrs) do
    resident
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> unique_constraint(:name)
  end
end
