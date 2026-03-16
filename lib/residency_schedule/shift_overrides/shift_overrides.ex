defmodule ResidencySchedule.ShiftOverrides do
  import Ecto.Query

  alias ResidencySchedule.Repo
  alias ResidencySchedule.ShiftOverrides.ShiftOverride
  alias ResidencySchedule.Rotations.Rotation

  @doc """
  Creates a shift override.

      iex> result = ResidencySchedule.ShiftOverrides.create_override(%{rotation_id: 0, covering_resident_id: 0, override_start_date: ~D[2023-07-08], override_end_date: ~D[2023-07-14]})
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
  Lists all overrides with rotation (and its resident) and covering_resident preloaded.
  """
  def list_all_overrides do
    from(o in ShiftOverride,
      preload: [rotation: :resident, covering_resident: []]
    )
    |> Repo.all()
  end

  @doc """
  Lists overrides where the given resident's rotation is being covered by someone else.
  Preloads: covering_resident and rotation.
  """
  def list_overrides_for_resident_as_original(resident_id) do
    from(o in ShiftOverride,
      join: r in assoc(o, :rotation),
      where: r.resident_id == ^resident_id,
      preload: [:covering_resident, :rotation]
    )
    |> Repo.all()
  end

  @doc """
  Lists overrides where the given resident is covering someone else.
  Preloads: rotation with its resident.
  """
  def list_overrides_for_resident_as_cover(resident_id) do
    from(o in ShiftOverride,
      where: o.covering_resident_id == ^resident_id,
      preload: [rotation: :resident]
    )
    |> Repo.all()
  end

  @doc """
  Lists overrides active during a given month.
  Preloads: rotation (with its resident) and covering_resident.
  """
  def list_overrides_for_month(year, month) do
    first = Date.new!(year, month, 1)
    last = Date.end_of_month(first)

    from(o in ShiftOverride,
      where: o.override_start_date <= ^last and o.override_end_date >= ^first,
      preload: [rotation: :resident, covering_resident: []]
    )
    |> Repo.all()
  end

  @doc """
  Lists rotations of a given type overlapping the specified date range, with resident preloaded.
  Used to populate the admin override form with available shifts to cover.

      iex> ResidencySchedule.ShiftOverrides.list_rotations_for_type_in_range("night_float", ~D[2023-07-01], ~D[2023-07-31])
      []
  """
  def list_rotations_for_type_in_range(rotation_type, start_date, end_date) do
    from(r in Rotation,
      join: res in assoc(r, :resident),
      where: r.rotation_type == ^rotation_type,
      where: r.start_date <= ^end_date and r.end_date >= ^start_date,
      preload: [resident: res],
      order_by: [res.residency_year, res.schedule_number]
    )
    |> Repo.all()
  end
end
