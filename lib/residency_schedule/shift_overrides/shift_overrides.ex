defmodule ResidencySchedule.ShiftOverrides do
  import Ecto.Query

  alias ResidencySchedule.Repo
  alias ResidencySchedule.ShiftOverrides.ShiftOverride
  alias ResidencySchedule.Rotations.Rotation
  alias ResidencySchedule.Residents.ScheduleResident

  @doc """
  Creates a shift override.

      iex> result = ResidencySchedule.ShiftOverrides.create_override(%{rotation_id: 0, covering_schedule_resident_id: 0, override_start_date: ~D[2023-07-08], override_end_date: ~D[2023-07-14]})
      iex> match?({:ok, _}, result) or match?({:error, _}, result)
      true
  """
  def create_override(attrs) do
    %ShiftOverride{}
    |> ShiftOverride.changeset(attrs)
    |> Repo.insert()
  end

  @doc """
  Deletes a shift override by id.
  """
  def delete_override(id) do
    Repo.get!(ShiftOverride, id) |> Repo.delete()
  end

  @doc """
  Lists all overrides with rotation (and its schedule_resident) and covering_schedule_resident preloaded.
  Schedule resident virtual name fields are populated from the associated Resident.
  """
  def list_all_overrides do
    sr_query = ScheduleResident.with_name_query()

    from(o in ShiftOverride,
      preload: [rotation: [schedule_resident: ^sr_query], covering_schedule_resident: ^sr_query]
    )
    |> Repo.all()
  end

  @doc """
  Lists overrides where the given schedule resident's rotation is being covered by someone else.
  Preloads: covering_schedule_resident and rotation.
  """
  def list_overrides_for_resident_as_original(schedule_resident_id) do
    sr_query = ScheduleResident.with_name_query()

    from(o in ShiftOverride,
      join: r in assoc(o, :rotation),
      where: r.schedule_resident_id == ^schedule_resident_id,
      preload: [covering_schedule_resident: ^sr_query, rotation: []]
    )
    |> Repo.all()
  end

  @doc """
  Lists overrides where the given schedule resident is covering someone else.
  Preloads: rotation with its schedule_resident.
  """
  def list_overrides_for_resident_as_cover(schedule_resident_id) do
    sr_query = ScheduleResident.with_name_query()

    from(o in ShiftOverride,
      where: o.covering_schedule_resident_id == ^schedule_resident_id,
      preload: [rotation: [schedule_resident: ^sr_query]]
    )
    |> Repo.all()
  end

  @doc """
  Lists overrides active during a given month.
  Preloads: rotation (with its schedule_resident) and covering_schedule_resident.
  Schedule resident virtual name fields are populated from the associated Resident.
  """
  def list_overrides_for_month(year, month) do
    first = Date.new!(year, month, 1)
    last = Date.end_of_month(first)
    sr_query = ScheduleResident.with_name_query()

    from(o in ShiftOverride,
      where: o.override_start_date <= ^last and o.override_end_date >= ^first,
      preload: [rotation: [schedule_resident: ^sr_query], covering_schedule_resident: ^sr_query]
    )
    |> Repo.all()
  end

  @doc """
  Lists overrides overlapping an inclusive date range across all schedules.
  Preloads: rotation (with its schedule_resident) and covering_schedule_resident.
  Schedule resident virtual name fields are populated from the associated Resident.

  Powers the calendar's week and day views, which span arbitrary date ranges
  rather than a single calendar month.

      iex> ResidencySchedule.ShiftOverrides.list_overrides_in_range(~D[2000-01-01], ~D[2000-01-07])
      []
  """
  def list_overrides_in_range(range_start, range_end) do
    sr_query = ScheduleResident.with_name_query()

    from(o in ShiftOverride,
      where: o.override_start_date <= ^range_end and o.override_end_date >= ^range_start,
      preload: [rotation: [schedule_resident: ^sr_query], covering_schedule_resident: ^sr_query]
    )
    |> Repo.all()
  end

  @doc """
  Lists shift overrides for a schedule that overlap an inclusive date range.

  Preloads `rotation` (with `schedule_resident`) and `covering_schedule_resident`.

  Exempt from doctest — hits the database. See `ShiftOverridesTest`.
  """
  def list_overrides_for_schedule_in_range(schedule_id, range_start, range_end) do
    sr_query = ScheduleResident.with_name_query()

    from(o in ShiftOverride,
      join: r in assoc(o, :rotation),
      join: sr in assoc(r, :schedule_resident),
      where: sr.schedule_id == ^schedule_id,
      where: o.override_start_date <= ^range_end and o.override_end_date >= ^range_start,
      preload: [rotation: [schedule_resident: ^sr_query], covering_schedule_resident: ^sr_query]
    )
    |> Repo.all()
  end

  @doc """
  Lists rotations of a given type overlapping the specified date range, with schedule_resident preloaded.
  Used to populate the admin override form with available shifts to cover.

      iex> ResidencySchedule.ShiftOverrides.list_rotations_for_type_in_range("night_float", ~D[2023-07-01], ~D[2023-07-31])
      []
  """
  def list_rotations_for_type_in_range(rotation_type, start_date, end_date) do
    sr_query = ScheduleResident.with_name_query()

    from(r in Rotation,
      join: sr in assoc(r, :schedule_resident),
      where: r.rotation_type == ^rotation_type,
      where: r.start_date <= ^end_date and r.end_date >= ^start_date,
      preload: [schedule_resident: ^sr_query],
      order_by: [sr.residency_year, sr.schedule_number]
    )
    |> Repo.all()
  end
end
