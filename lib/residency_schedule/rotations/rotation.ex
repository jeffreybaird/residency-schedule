defmodule ResidencySchedule.Rotations.Rotation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "rotations" do
    field :rotation_type, :string
    field :start_date, :date
    field :end_date, :date
    field :slot_index, :integer

    belongs_to :schedule_resident, ResidencySchedule.Residents.ScheduleResident

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for creating or updating a rotation.

      iex> changeset = ResidencySchedule.Rotations.Rotation.changeset(%ResidencySchedule.Rotations.Rotation{}, %{schedule_resident_id: 1, rotation_type: "oncology", start_date: ~D[2023-07-03], end_date: ~D[2023-07-07], slot_index: 0})
      iex> changeset.valid?
      true
  """
  def changeset(rotation, attrs) do
    rotation
    |> cast(attrs, [:schedule_resident_id, :rotation_type, :start_date, :end_date, :slot_index])
    |> validate_required([
      :schedule_resident_id,
      :rotation_type,
      :start_date,
      :end_date,
      :slot_index
    ])
  end
end
