defmodule ResidencySchedule.Residents.Resident do
  use Ecto.Schema
  import Ecto.Changeset

  schema "residents" do
    field :name, :string
    field :calendar_token, :string

    has_many :schedule_residents, ResidencySchedule.Residents.ScheduleResident

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a resident (person). The calendar token
  identifies the person's feed URL and stays the same across every academic
  year they appear in.

      iex> changeset = ResidencySchedule.Residents.Resident.changeset(
      ...>   %ResidencySchedule.Residents.Resident{},
      ...>   %{name: "Briar", calendar_token: "7f5a0c2e-1d3b-4c8a-9e6f-0a1b2c3d4e5f"}
      ...> )
      iex> changeset.valid?
      true
  """
  def changeset(resident, attrs) do
    resident
    |> cast(attrs, [:name, :calendar_token])
    |> validate_required([:name, :calendar_token])
    |> unique_constraint(:name)
    |> unique_constraint(:calendar_token)
  end
end
