defmodule ResidencySchedule.ShiftOverrides.ShiftOverride do
  use Ecto.Schema
  import Ecto.Changeset

  alias ResidencySchedule.Rotations.Rotation
  alias ResidencySchedule.Residents.Resident

  schema "shift_overrides" do
    belongs_to :rotation, Rotation
    belongs_to :covering_resident, Resident
    field :override_start_date, :date
    field :override_end_date, :date
    timestamps(type: :utc_datetime)
  end

  @doc """
  Validates a shift override changeset.

      iex> attrs = %{rotation_id: 1, covering_resident_id: 2, override_start_date: ~D[2023-07-08], override_end_date: ~D[2023-07-14]}
      iex> cs = ResidencySchedule.ShiftOverrides.ShiftOverride.changeset(%ResidencySchedule.ShiftOverrides.ShiftOverride{}, attrs)
      iex> cs.valid?
      true
  """
  def changeset(override, attrs) do
    override
    |> cast(attrs, [:rotation_id, :covering_resident_id, :override_start_date, :override_end_date])
    |> validate_required([:rotation_id, :covering_resident_id, :override_start_date, :override_end_date])
    |> validate_date_order()
  end

  defp validate_date_order(changeset) do
    start = get_field(changeset, :override_start_date)
    finish = get_field(changeset, :override_end_date)

    if start && finish && Date.compare(start, finish) == :gt do
      add_error(changeset, :override_end_date, "must be on or after start date")
    else
      changeset
    end
  end
end
