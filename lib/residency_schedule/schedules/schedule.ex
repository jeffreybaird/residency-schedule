defmodule ResidencySchedule.Schedules.Schedule do
  use Ecto.Schema
  import Ecto.Changeset

  schema "schedules" do
    field :academic_year, :integer
    field :label, :string

    has_many :schedule_residents, ResidencySchedule.Residents.ScheduleResident

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a schedule.

      iex> changeset = ResidencySchedule.Schedules.Schedule.changeset(%ResidencySchedule.Schedules.Schedule{}, %{academic_year: 2026, label: "2026–2027"})
      iex> changeset.valid?
      true
  """
  def changeset(schedule, attrs) do
    schedule
    |> cast(attrs, [:academic_year, :label])
    |> validate_required([:academic_year, :label])
    |> unique_constraint(:academic_year)
  end
end
