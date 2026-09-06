defmodule ResidencySchedule.ChangeRequests.ChangeRequest do
  @moduledoc """
  A request for one resident to cover part of another resident's rotation.
  Requests start `pending`; an admin approves (creating a `ShiftOverride`) or
  denies them, and the requester may cancel while still pending.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @statuses [:pending, :approved, :denied, :cancelled]

  schema "schedule_change_requests" do
    field :start_date, :date
    field :end_date, :date
    field :status, Ecto.Enum, values: @statuses, default: :pending
    field :note, :string
    field :reviewed_at, :utc_datetime
    field :review_note, :string

    belongs_to :rotation, ResidencySchedule.Rotations.Rotation
    belongs_to :covering_schedule_resident, ResidencySchedule.Residents.ScheduleResident
    belongs_to :requested_by_user, ResidencySchedule.Accounts.User
    belongs_to :reviewed_by_user, ResidencySchedule.Accounts.User
    belongs_to :shift_override, ResidencySchedule.ShiftOverrides.ShiftOverride

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for filing a request.

      iex> cs = ResidencySchedule.ChangeRequests.ChangeRequest.changeset(
      ...>   %ResidencySchedule.ChangeRequests.ChangeRequest{},
      ...>   %{rotation_id: 1, covering_schedule_resident_id: 2, requested_by_user_id: 3,
      ...>     start_date: ~D[2026-09-07], end_date: ~D[2026-09-08]}
      ...> )
      iex> cs.valid?
      true
  """
  def changeset(request, attrs) do
    request
    |> cast(attrs, [
      :rotation_id,
      :covering_schedule_resident_id,
      :requested_by_user_id,
      :start_date,
      :end_date,
      :note
    ])
    |> validate_required([
      :rotation_id,
      :covering_schedule_resident_id,
      :requested_by_user_id,
      :start_date,
      :end_date
    ])
    |> validate_date_order()
  end

  @doc """
  Changeset for an admin decision on a pending request.

      iex> cs = ResidencySchedule.ChangeRequests.ChangeRequest.review_changeset(
      ...>   %ResidencySchedule.ChangeRequests.ChangeRequest{status: :pending},
      ...>   %{status: :approved, reviewed_by_user_id: 1, reviewed_at: ~U[2026-09-06 12:00:00Z]}
      ...> )
      iex> cs.valid?
      true
  """
  def review_changeset(request, attrs) do
    request
    |> cast(attrs, [:status, :reviewed_by_user_id, :reviewed_at, :review_note, :shift_override_id])
    |> validate_required([:status, :reviewed_by_user_id, :reviewed_at])
    |> validate_inclusion(:status, [:approved, :denied])
  end

  @doc """
  Returns the list of request statuses.

      iex> ResidencySchedule.ChangeRequests.ChangeRequest.statuses()
      [:pending, :approved, :denied, :cancelled]
  """
  def statuses, do: @statuses

  defp validate_date_order(changeset) do
    start = get_field(changeset, :start_date)
    finish = get_field(changeset, :end_date)

    if start && finish && Date.compare(start, finish) == :gt do
      add_error(changeset, :end_date, "must be on or after start date")
    else
      changeset
    end
  end
end
